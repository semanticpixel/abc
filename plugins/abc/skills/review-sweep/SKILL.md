---
name: review-sweep
description: Scan all open PRs (GitHub) and MRs (GitLab) the user authored, triage unresolved reviewer threads via the abc:triage subagent, present a dashboard of fixable vs judgment-required items, and apply confirmed fixes per PR/MR. Auto-detects which platforms to scan. TRIGGER when the user says "/review-sweep", "sweep my MRs", "triage my open PRs", or wants to bulk-process reviewer feedback. Designed to compose with /loop for periodic sweeps.
argument-hint: "[github | gitlab | both]  (default: both)"
model: opus
allowed-tools:
  - Skill
  - Agent
  - Read
  - Grep
  - Glob
  - AskUserQuestion
  - Bash(git status:*)
  - Bash(git log:*)
  - Bash(git diff:*)
  - Bash(git fetch:*)
  - Bash(git checkout:*)
  - Bash(git switch:*)
  - Bash(git add:*)
  - Bash(git commit:*)
  - Bash(git push:*)
  - Bash(git remote:*)
  - Bash(git branch:*)
  - Bash(gh auth status:*)
  - Bash(gh search prs:*)
  - Bash(gh pr view:*)
  - Bash(gh pr diff:*)
  - Bash(gh pr checkout:*)
  - Bash(gh pr comment:*)
  - Bash(gh api:*)
  - Bash(glab auth status:*)
  - Bash(glab mr list:*)
  - Bash(glab mr view:*)
  - Bash(glab mr checkout:*)
  - Bash(glab mr note:*)
  - Bash(pnpm:*)
  - Bash(npm:*)
  - Bash(yarn:*)
  - Bash(npx:*)
  - mcp__gitlab__list_user_merge_requests
  - mcp__gitlab__get_merge_request
  - mcp__gitlab__list_merge_request_diffs
  - mcp__gitlab__discussion_list
  - mcp__gitlab__discussion_add_note
  - mcp__gitlab__discussion_resolve
---

# /abc:review-sweep — Bulk triage your open PRs and MRs

Scan every open PR/MR you authored across GitHub and GitLab, fetch unresolved reviewer threads, hand each comment to the `abc:triage` subagent for classification, present a dashboard, and apply only the fixes you confirm.

**Composes with `/loop`** for periodic sweeps: `/loop 30m /abc:review-sweep` keeps the queue swept while you work on other things.

## Hard rules

- **Never** auto-apply fixes without an explicit user confirmation gate. The skill is a triage and proposal tool, not a hands-off auto-fixer.
- **Never** resolve a reviewer thread automatically — only after the corresponding fix is pushed and the user has approved replying. Even then, prefer "reply with fix SHA" over "resolve" so the reviewer keeps control.
- **Never** push to `main`/`master`. Only push to the PR/MR's source branch.
- **Stop at the first `judgment-required`** when applying fixes to a given PR/MR — don't blast through a thread of mixed-judgment items.
- Skip drafts unless the user passes `--include-drafts`.
- **Phase 1.5 may push to source branches** as part of the auto-rebase health pre-pass — under the same self-cheating-hard-stop rule that applies to fix application (see Phase 1.5 and Phase 5). No `--no-verify`, no test deletions, no assertion widening, even when the only way to make the rebased branch pass gates is to weaken a check.

## Workflow

### Phase 0: Parse args, verify auth

`$ARGUMENTS` selects platforms:
- empty / `both` → scan GitHub AND GitLab (default)
- `github` → GitHub only
- `gitlab` → GitLab only

Run auth pre-flight in parallel for the targeted platforms:
- GitHub: `gh auth status` — if not authed, skip GitHub scan and surface the re-auth command.
- GitLab: `glab auth status` — same fallback.

If both fail, abort with the re-auth commands. Don't degrade silently.

### Phase 1: Enumerate the user's open PRs/MRs

In parallel per platform:

**GitHub** (cross-repo, via search API):
```
gh search prs --author=@me --state=open --json url,number,title,repository,isDraft,updatedAt --limit 50
```

**GitLab** (cross-project, via MCP):
- `mcp__gitlab__list_user_merge_requests` with `state: opened`, `author_username: <user>` — the user's username comes from `glab auth status` output, parse it.

Filter out drafts unless `--include-drafts` was passed. Drop any PR/MR with no recent activity (no updates in 60+ days) — too stale to sweep cleanly.

If the resulting list is empty: print "No open PRs/MRs with reviewer activity. Inbox zero." and return.

### Phase 1.5: PR/MR health pre-pass — attempt auto-rebase

Runs once per enumerated PR/MR, **before** triage. The goal: a PR that's behind `main`/`master` but otherwise mergeable shouldn't appear in the dashboard as "stalled" — most parallel-work conflicts are textual (multiple PRs adding imports to the same file, JSX elements to the same component, lines to the same array) and resolvable by git's three-way merge. Phase 1.5 tries the mechanical resolution before the dashboard renders.

Per PR/MR, in parallel where possible:

1. **Mergeable check.**
   - GitHub: `gh api /repos/<owner>/<repo>/pulls/<num>` and read the `mergeable` field. (GitHub computes this asynchronously; a `null` value means "still computing" — treat as `true` for this pass so we don't block on stale state. A subsequent sweep will catch it.)
   - GitLab: `mcp__gitlab__get_merge_request` and read the equivalent field.
2. **`mergeable: true`** → mark health-OK. Continue to Phase 2 as today.
3. **`mergeable: false`** → resolve the local workdir via the same `repo:` label + cwd lookup Phase 5 already uses (head-branch repo → matching subdirectory of cwd, or known-mapping fallback). If no local workdir is resolvable → surface in the dashboard as **`no local clone available — rebase manually`**. Skip Phase 2+ for this PR/MR.
4. **Local workdir resolved** → `gh pr checkout <num>` (or `glab mr checkout <iid>`). `git fetch origin`. `git rebase origin/<base>`.
5. **Conflict markers remain** → `git rebase --abort`. Surface in the dashboard as **`needs manual rebase: <conflicted-file-paths>`**. Skip Phase 2+ for this PR/MR.
6. **Clean rebase (no markers)** → run the repo's local gates — the same `pnpm typecheck && pnpm test` / `package.json` script invocation that Phase 5 uses post-fix.
7. **Gates fail after clean rebase** → `git rebase --abort` (back to the pre-rebase tip). Surface in the dashboard as **`rebased clean but gates failed: <top-20-lines-of-output>`**. Skip Phase 2+ for this PR/MR.
8. **Gates pass** → `git push --force-with-lease`. Post `<!-- review-sweep:health:rebased -->` as a **marker-only** comment on the PR/MR — the marker is the entire comment body, no trailing prose. Matches the convention of the other `<!-- ship-issue:* -->` / `<!-- review-sweep:* -->` markers (e.g. `<!-- ship-issue:commit -->`, `<!-- ship-issue:rebase:auto -->`): downstream skills grep for the marker as a yes/no signal, and free-form prose breaks the match across revisions. The rebase SHA range is already captured in the commit log for forensic reading. If a human-readable timeline note is also wanted, post it as a *separate* PR/MR comment that does NOT contain the marker so the two signals stay decoupled. Mark health-OK. Continue to Phase 2.

**Self-cheating hard stop (verbatim, applies inside Phase 1.5 too):**

> If the skill catches itself about to bypass a failing check rather than fix it — deleting a failing assertion so tests pass, adding `--no-verify` to a commit, widening a type to suppress an error, wrapping a failing line in `// @ts-expect-error`, `.skip()`-ing a test that was failing, commenting out a lint rule that was firing, `eslint-disable`-ing a violation to silence it — **hard stop**. No self-healing, no "I'll come back and fix it properly," no silent retry. Surface the attempted-cheat in the dashboard so the user can see exactly what the skill was about to do.

In Phase 1.5 specifically: if the only way to make gates pass after a clean rebase is to delete or weaken an assertion, abort the rebase (step 7's `--abort` path) and surface as `rebased clean but gates failed` — never push a "fixed" rebase that's actually a cheat.

The dashboard (Phase 4) renders health-pre-pass outcomes on their own lines so successful auto-rebases (`✓ rebased`, marker posted) and rebase-escalations (`needs manual rebase`, `gates failed`, `no local clone`) are distinguishable at a glance.

### Phase 2: Per-PR/MR, fetch unresolved threads

For each PR/MR (in parallel where possible — `gh api` calls are cheap, GitLab MCP calls can run concurrently per project):

**GitHub**: `gh api /repos/<owner>/<repo>/pulls/<num>/comments --paginate` for inline review comments. Filter for:
- Threads where the LATEST comment is from a reviewer (not the PR author).
- Threads without a "resolved" marker — note GitHub doesn't have native thread resolution; treat a comment from the author replying "Done" / "Fixed in <sha>" as resolved.

**GitLab**: `mcp__gitlab__discussion_list` — each discussion has a `resolved` boolean. Filter for `resolved: false`. Skip discussions where the latest note is from the MR author.

Skip PRs/MRs with zero unresolved threads.

### Phase 3: Triage each comment via abc:reviewer or abc:triage

For each unresolved comment, dispatch the `abc:triage` subagent (use the `Agent` tool with `subagent_type: triage`). Pass:

- The comment body
- The file path + line
- A 10-20 line diff hunk around the comment (fetch via `gh pr diff` or `mcp__gitlab__list_merge_request_diffs` once per PR/MR, then slice)
- Thread context (prior replies) if multi-turn
- Author bot/human metadata

**Parallelize** — fire all triage subagents for a PR/MR at once. They're independent.

Each subagent returns the structured YAML (see `triage` agent contract). Collect responses per PR/MR.

### Phase 4: Aggregate and present the dashboard

After all triage subagents return, print a per-PR/MR dashboard. Phase 1.5 health-pre-pass outcomes are rendered as a `health:` line per PR/MR so successful auto-rebases and escalations are distinguishable at a glance:

```
/abc:review-sweep — <N> PRs/MRs, <M> unresolved threads

[1] acme/web#4521  "Add WidgetRow to dashboard"
    health: ✓ rebased on origin/main (gates green; marker posted)
    └─ src/WidgetRow.tsx:42  [fixable-code, high]
       "Use `useMemo` for the derived rows array"
       → const rows = useMemo(() => derive(input), [input]);
    └─ src/WidgetRow.module.css:18  [fixable-doc, high]
       "Hardcoded color, use --color-text-primary"
    └─ src/WidgetRow.tsx:88  [judgment-required, medium]
       "Should this handle the empty state differently?"

[2] eng/super-funnel!231  "Auto-approve threshold tuning"
    health: ✓ mergeable (no rebase needed)
    └─ rules/single_dir.yaml:14  [question, high]
       "Why 0.6 not 0.7?"

[3] acme/web#4530  "Sidebar navigation refactor"
    health: ⚠ needs manual rebase: src/Sidebar.tsx, src/routes.ts
    (skipped triage)

[4] acme/web#4531  "Update form validation"
    health: ⚠ rebased clean but gates failed: 2 type-errors in src/forms/Field.tsx
    (skipped triage)

[5] acme/other#9  "Hot-fix typo in helper"
    health: ⚠ no local clone available — rebase manually
    (skipped triage)

Summary: 2 fixable-code, 1 fixable-doc, 1 judgment-required, 1 question · 1 auto-rebased · 3 health-escalations
```

Then ask via `AskUserQuestion`:

- **Apply all fixable-code + fixable-doc** (skipping judgment-required and questions)
- **Apply only fixable-doc** (lower risk batch)
- **Pick per-PR** — I'll prompt for each PR/MR individually
- **Just show the report, don't apply** — exit, leave for me to handle manually

### Phase 5: Apply fixes per PR/MR

For each PR/MR the user chose to act on:

1. Determine the workdir (look up the PR/MR's head branch's repo from the cwd's git remote, OR use a known mapping — if neither, prompt for the local path).
2. `git fetch` and `gh pr checkout <num>` / `glab mr checkout <iid>`.
3. Apply each `fixable-code`/`fixable-doc` change as proposed. Use the `suggestion` block contents from the triage output.
4. Run the repo's type-check and tests (`pnpm typecheck`, `pnpm test`, or the equivalent from `package.json` scripts). **Abort this PR/MR if anything fails** — leave the branch as-is, report the failure, move on to the next PR/MR.
5. Commit with a message like: `Address review feedback on <thread topic>` — no AI footer. Use HEREDOC.
6. Push to the PR/MR's source branch.
7. **Reply (do not resolve)** to each addressed thread with: `Fixed in <SHA>.` Use:
   - GitHub: `gh pr comment <num> --body "..."` for thread replies — note GitHub's inline reply API is `gh api /repos/.../pulls/comments/<id>/replies` if you want to nest under the original comment.
   - GitLab: `mcp__gitlab__discussion_add_note` with the discussion ID.

Surface each PR/MR's status after processing:

```
[1] acme/web#4521  ✓ 2 fixes applied, pushed <SHA>, 2 threads replied
[2] eng/super-funnel!231  — skipped (only question, no fixable items)
```

### Phase 6: Report judgment-required and questions

After applying fixes, print a separate "needs your input" block:

```
Needs your attention:

[1] acme/web#4521  src/WidgetRow.tsx:88
    "Should this handle the empty state differently?"
    Triage rationale: design decision needed — depends on whether empty is a valid runtime state.

[2] eng/super-funnel!231  rules/single_dir.yaml:14
    "Why 0.6 not 0.7?"
    Triage rationale: a reply with reasoning would close the thread.
```

These are intentionally left for the user to handle. Do not auto-reply, even to questions — the user's voice on judgment calls matters.

### Phase 7: Stop

Print a one-line summary:

```
Sweep complete: <X> PRs/MRs processed, <Y> fixes applied, <Z> threads pending your input.
```

Return. The skill is one-shot — do NOT self-arm `/loop`. If the user wants periodic sweeps, they wrap with `/loop 30m /abc:review-sweep`.

## Notes on edge cases

- **PR/MR with merge conflicts against main**: handled by Phase 1.5's auto-rebase health pre-pass. Trivial textual conflicts auto-resolve and get a `<!-- review-sweep:health:rebased -->` marker; non-trivial conflicts surface in the dashboard as `needs manual rebase: <files>` and skip Phase 2+ for that PR/MR.
- **Local repo not present for the PR/MR**: Phase 1.5 surfaces as `no local clone available — rebase manually` and skips Phase 2+ for that PR/MR. No interactive prompt — the dashboard line is the entire signal.
- **CI is red on the PR/MR**: still triage and apply fixes; the user might be fixing exactly the thing CI is failing on.
- **Same triage rule fires repeatedly across PRs**: still apply per-PR; don't try to deduplicate "the same fix" — it's per-PR per-branch.
- **code-review-bot findings with named rules**: classify as `fixable-code` if the rule has a mechanical fix, `judgment-required` if it's a design lint (architectural pattern violations).
