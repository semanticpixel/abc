---
name: ship-issue-gh
description: GitHub · GitHub-Issues sibling of /abc:ship-issue. Drives a GitHub issue (or list, or parent with task-list children) from `pending` to `merged` through the implement → PR → address-review → merge loop. Emulates Linear's state machine on top of GitHub Issues using the label conventions documented in scaffold-sub-issues-gh/github-conventions.md. TRIGGER when the user says "/ship-issue-gh <owner>/<repo>#<n>", asks to ship/land/drive a GitHub issue, or wants Claude to take a GitHub-tracked ticket through review to merge. Also trigger when resuming work on a GitHub issue with an open PR and pending reviewer comments. Self-arms its own `/loop` — the user invokes once and walks away.
argument-hint: "<owner>/<repo>#<n> | #<n> (in a git repo) | <owner>/<repo>#<n>,<owner>/<repo>#<m> | <owner>/<repo>#<parent> (walks task-list children) | milestone:<owner>/<repo>/<num-or-name> [--no-compact]"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash(git status:*)
  - Bash(git log:*)
  - Bash(git diff:*)
  - Bash(git fetch:*)
  - Bash(git pull:*)
  - Bash(git checkout:*)
  - Bash(git switch:*)
  - Bash(git add:*)
  - Bash(git commit:*)
  - Bash(git push:*)
  - Bash(git remote:*)
  - Bash(git branch:*)
  - Bash(git rebase:*)
  - Bash(gh pr:*)
  - Bash(gh api:*)
  - Bash(gh auth status:*)
  - Bash(gh run:*)
  - Bash(gh issue view:*)
  - Bash(gh issue comment:*)
  - Bash(gh issue edit:*)
  - Bash(gh issue close:*)
  - Bash(gh issue list:*)
  - Bash(gh label create:*)
  - Bash(cd:*)
  - Bash(ls:*)
  - Bash(pwd:*)
  - Bash(pnpm:*)
  - Bash(npm:*)
  - Bash(npx:*)
  - Bash(yarn:*)
  - Bash(node:*)
  - AskUserQuestion
---

Drive a GitHub issue (or ordered list of issues, or parent issue with a managed `## Sub-issues` task-list) from `pending` to `merged` through the implement → open-PR → address-review → merge loop. GitHub-only. Stateless across sessions — GitHub Issues + the PR's check runs are the sources of truth.

**Usage:** `/ship-issue-gh <arg>` — the skill self-arms its own `/loop`. Invoke once and walk away.

Where `<arg>` is one of:

- A single issue: `<owner>/<repo>#<n>` (or `#<n>` when invoked inside the target repo's git working copy)
- A comma-separated ordered list (each entry must be fully qualified — no `#<n>` shorthand in a list, since the list can span repos): `<owner>/<repo>#<65>,<owner>/<repo>#<66>`
- A **parent issue** with a managed `## Sub-issues` task-list — children are resolved from the task-list and walked in body order
- A **milestone**: `milestone:<owner>/<repo>/<num-or-name>` — expands to the milestone's non-terminal issues, ordered by `createdAt` ascending

Any shape may carry a trailing `--no-compact` flag to suppress the compact-on-merge prompt — see [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

> The architecture (state machine, blocked-user triggers, escape hatches, locked decisions) lives in `DESIGN.md` alongside this file. The label scheme + marker comments + task-list fence live in `../scaffold-sub-issues-gh/github-conventions.md`. Read both before changing behavior. This file is the operational procedure.

---

## Phase 0: Parse input

Normalize `$ARGUMENTS` into an ordered list of fully-qualified `<owner>/<repo>#<n>` IDs.

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-on-merge prompt (Phase 4 § `merged`) is skipped at every trigger boundary. Contract and rationale live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md). Shape detection below runs on the flag-stripped string.

### Shape detection (in order, first match wins)

1. **Starts with `milestone:`** → milestone expansion (below).
2. **Matches a GitHub issue URL** (`https://github.com/<owner>/<repo>/issues/<n>`, optionally with Enterprise host) → extract `<owner>/<repo>#<n>`, continue as single ID.
3. **Contains a comma** → split on commas; every entry must match `<owner>/<repo>#<n>` after trimming (no `#<n>` shorthand in lists — ambiguous across repos). Otherwise → `blocked-user`.
4. **Matches `#<n>` alone** → resolve `<owner>/<repo>` from `git -C <cwd> remote get-url origin`. If cwd is not in a git repo, or origin isn't a GitHub URL → `blocked-user` with reason `bare-issue-num-needs-cwd-in-github-repo`. Continue as single ID.
5. **Matches `<owner>/<repo>#<n>`** → check for a managed task-list. Fetch the issue body via `gh issue view <n> --repo <owner>/<repo> --json body,labels,state,state_reason,closedByPullRequestsReferences,milestone`. If the body contains a `<!-- ship-epic:sub-issues:start -->` ... `<!-- ship-epic:sub-issues:end -->` block with one or more `- [ ] <ref>` lines, **expand to the children** in body order (preserving `[x]`-completed entries for state derivation but skipping them for work selection). Otherwise, keep as single ID.

### Milestone expansion

For `milestone:<owner>/<repo>/<num-or-name>`:

1. **Resolve the milestone.** `gh api /repos/<owner>/<repo>/milestones?state=all --jq '.[] | select(.number == <num> or .title == "<name>")'`. If no match → `blocked-user` with reason `milestone-not-found:<spec>`. Do not proceed to Phase 0.5 — no cron arming.
2. **Fetch open + non-`completed` issues.** `gh issue list --repo <owner>/<repo> --milestone <number> --state all --json number,title,state,stateReason,createdAt,labels --limit 250`. Paginate via `--limit` + `--search` cursors if 250 isn't enough; in practice a milestone has fewer.
3. **Client-side filter.** Drop terminal issues — `state=closed AND stateReason=completed` is "Done"; `state=closed AND stateReason=not_planned` is "Canceled". Both are terminal — skip. Open issues are kept regardless of `status:*` labels.
4. **Empty-list guard.** If the resulting list is empty → `blocked-user` with reason `milestone-no-open-issues:<spec>`. Do not arm the cron.
5. Sort the keepers by `createdAt` ascending. Rewrite each as `<owner>/<repo>#<n>`. The resulting ordered list becomes the work queue. Phase 1 onward is unchanged.

**Ordering caveat** (document inline on the first wake's output): ordering is `createdAt` ascending. Pass a comma-separated list in the desired order if you need to override.

### Raw-arg retention

Retain the **raw arg string** (as the user typed it — e.g. `<owner>/<repo>#42,<owner>/<repo>#43`, `milestone:<owner>/<repo>/3`, `<owner>/<repo>#100`, NOT the expanded list) for the self-arming check in Phase 0.5. It's the match key for `CronList` and `CronDelete`. For milestone args specifically, one loop polls the same milestone across wakes — new issues added to the milestone mid-flight get picked up on the next wake's re-derivation without spawning a second loop.

A `--no-compact` flag is part of the raw arg string — it stays in the cron entry's command so the opt-out survives every subsequent wake (the skill persists nothing locally; the cron arg is the only carrier — see `../_shared/compact-on-merge.md` § `--no-compact`).

The user's order is respected. The skill does not re-prioritise.

## Phase 0.5: Self-arm the loop (load-bearing)

Identical contract to the Linear sibling's Phase 0.5 — the skill arms its own `/loop` so the user invokes once and walks away. Runs on every wake, including loop-triggered ones; the idempotent match below makes subsequent wakes a no-op.

### Cron-entry match rule

Defined once here, referenced by name in Phase 7's self-cancel — these two checks must stay in lockstep.

> A `CronList` entry **matches** this invocation when its command string contains `<command-name> <raw-arg>` **followed by a word boundary** — the next character (if any) must NOT be alphanumeric, `-`, `,`, `/`, or `#`. `<command-name>` is the literal slash-command name Claude Code injects for this invocation (e.g. `/ship-issue-gh` when invoked top-level, or `/<plugin>:ship-issue-gh` when invoked through a plugin namespace — verify from the `<command-name>` tag Claude Code passes at invocation time, including on `/loop`-triggered wakes where the inner command name is still surfaced).
>
> Reading the **actually-injected** name — rather than hardcoding `/ship-issue-gh` — is load-bearing for plugin-namespaced invocations: the hardcoded substring `/ship-issue-gh` is **not** present in `/abc:ship-issue-gh <raw-arg>` (the prefix is `/abc:`, not `/`), so the match always failed and every wake duplicate-armed a new cron.
>
> **Fallback regex** when `<command-name>` isn't reachable (older Claude Code versions, edge cases): test the entry's command string against `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue-gh <raw-arg>(?![A-Za-z0-9_,/#-])`. The optional `<plugin>:` prefix capture covers any plugin-namespacing scheme; the trailing negative-lookahead is the same boundary class as the strict rule. This still prevents `foo/bar#1` from false-matching an entry for `foo/bar#10` (prefix) or `foo/bar#1,foo/bar#2` (comma continuation). The `/` and `#` exclusions are GitHub-ID specific; the Linear sibling's rule doesn't need them.
>
> Boundary check works whether `CronList` reports the wrapped form `/loop 6m <command-name> <raw-arg>` or the inner `<command-name> <raw-arg>`.

### Arm check

1. Call `CronList` to enumerate active scheduled tasks in the current session.
2. Apply the cron-entry match rule above to each entry.
3. If a match is found → no-op, proceed to Phase 1. This is the common path on loop-triggered wakes.
4. If no match → the user invoked `<command-name> <raw-arg>` directly without a `/loop` wrapper (the expected first-invocation case). Invoke `Skill(skill: "loop", args: "6m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1.

**Match key is the full raw arg string.** Two separate invocations with different args → two independent loops.

Proceed to Phase 1 in both cases — the first wake also does the work of the first iteration.

## Phase 1: Resolve each item (repo + workdir)

For **each** item in the list, apply the per-item resolution rule:

1. Fetch the issue: `gh issue view <n> --repo <owner>/<repo> --json number,title,state,stateReason,labels,body,closedAt,closedByPullRequestsReferences,milestone`. Capture labels.
2. Collect any label names starting with `repo:`.
3. Apply this decision table:

   | Count of `repo:` labels | Action |
   |---|---|
   | 0 | Use a workdir derived from the issue's `<owner>/<repo>` — look for a subdirectory of cwd matching `<repo>`. If missing, fall back to using cwd itself **only if** `git remote get-url origin` matches `<owner>/<repo>`. Otherwise → `blocked-user`. |
   | 1 | Extract `<name>` from `repo:<name>`. Look for a subdirectory of cwd matching `<name>`. If missing → `blocked-user` with a note listing available subdirs. |
   | 2+ | `blocked-user` — one item resolves to at most one repo. |

4. Verify `git -C <workdir> remote get-url origin` resolves to the same `<owner>/<repo>` (or compatible host alias). If they disagree → `blocked-user` with reason `repo-label-mismatches-workdir-remote`.
5. Confirm CLI auth: `gh auth status --hostname <derived-from-remote-url>`. If not authed → `blocked-user` with the auth command to run.

**Cache** the resolved `{workdir, owner, repo}` tuple per issue for this invocation. Re-resolution on the next `/loop` wake is cheap and handles the case where the user added/removed a label mid-flight.

**`gh` version check.** On the first wake, run `gh --version` and confirm `>= 2.40` (required for reliable `--json body` on `gh issue view`). If older → `blocked-user` with the upgrade command.

## Phase 2: Pick the next item

Walk the list in order. For each item, derive its current state (Phase 3). The skill works on **one issue at a time** — serialisation is deliberate.

Skip items already in `merged`. Work the first non-terminal item. If any item is in `failed` or `blocked-user`, halt the whole loop — see Phase 7.

## Phase 3: Derive current state

### Data to gather

Gather, for the current issue:

- Issue state (the Phase 1 fetch above; refresh if the wake is > 30s old).
- Skill-authored comments via `gh api /repos/<owner>/<repo>/issues/<n>/comments --paginate --jq '.[] | {id, body, created_at, author: .user.login}'`. Filter to bodies containing `<!-- ship-issue:` markers.
- Linked PRs via the `closedByPullRequestsReferences` field on the issue plus `gh pr list --repo <owner>/<repo> --search "linked:<n>" --state all --json number,state,headRefName,url,mergedAt`.
- For any open PR: its review comments via `gh api /repos/<owner>/<repo>/pulls/<pr-num>/comments --paginate` plus check-runs via `gh pr checks <pr-num> --repo <owner>/<repo> --json name,state,conclusion`.

**If any of these reads fail** (non-zero exit, timeout, partial pagination the skill can't reconcile) → transition to `blocked-user` with reason `cannot-read-issue-state:<tool>:<detail>`. Do not fall through to the table — an unknown state is not "no match found." This matters most for row 1a: silently treating a failed comments list as "no `verify:passed` marker" would bypass the validation gate.

For CI checks specifically: `state=completed` with `conclusion=failure` are "failing"; `state=in_progress` and `state=queued` are **pending** (not failing). Only completed-failed checks drive rows 3a/3b.

### State table

Apply these rules **in order** — first match wins. Phase 3 is the single point of state decision.

| # | Condition | Derived state |
|---|---|---|
| 1a | A PR linked to this issue is **merged** AND the issue body has a `## Validation` section (matching rule below) AND no `<!-- ship-issue:verify:passed -->` comment exists | `blocked-verify` |
| 1 | A PR linked to this issue is **merged** (and 1a does not apply) | `merged` |
| 2 | A PR linked to this issue is **closed but not merged** | `failed` (surface the closed-PR URL, halt) |
| 3 | An **open PR** exists AND has review comments (human or code-review-bot) created *after* the last skill commit | `fixing` |
| 3a | An **open PR** exists, no new review comments since the last skill commit, AND one or more completed CI checks have `conclusion=failure` of the **assertion type** (unit test, lint, type check, code-review-bot check-run with findings) | `fixing` |
| 3b | An **open PR** exists, no new review comments since the last skill commit, AND one or more completed CI checks have `conclusion=failure` of the **infra/env type** (secrets missing, dependency resolution failure, runner error, no test output at all) | `blocked-user` (reason: `ci-infra-failure:<check-name>`) |
| 4 | An **open PR** exists, no new review comments, no failing CI checks | `pr-open` |
| 5 | No PR has ever existed, issue has `status:in-progress` or `status:in-review` label | `implementing` (resume — do not reset) |
| 6 | No PR, no `status:*` label | `pending` |

### Supporting rules

**Heading-match for row 1a's `## Validation`**: case-insensitive match on any heading at `##` level or deeper whose leading word is `Validation` — same rule as the Linear sibling. When ambiguous, err on the side of row 1a (transition to `blocked-verify`).

**Edge cases for rows 3a / 3b** — same per-check classification then row evaluation as the Linear sibling.

**Defining "the last skill commit"** (used in rows 3, 3a, 3b, 4): the most recent commit on the PR branch carrying the skill's commit marker. Check the `<!-- ship-issue:commit -->` HTML comment in the commit body first — this is the primary marker, written on every skill commit (see the **Skill-commit marker** rule below). Fall back to the legacy `Co-Authored-By: Claude` trailer for commits made before the HTML marker landed:

```
git -C <workdir> log <pr-branch> --grep="<!-- ship-issue:commit -->" -1 --format="%H %ai"
# if empty, fall back to the legacy trailer:
git -C <workdir> log <pr-branch> --grep="Co-Authored-By: Claude" -1 --format="%H %ai"
```

If neither marker exists on the branch, treat **all** open review comments as new.

**Skill-commit marker — what to write on commits** (Phase 4 references this rule by name):

- **Always** include a `<!-- ship-issue:commit -->` HTML comment line in the commit body. Anchors the Phase 3 lookup above and is scoped under the existing `<!-- ship-issue:* -->` namespace, so it doubles as a Skill-authored audit signal in `git log`.
- **By default**, also include a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer (exact string) for backward-compat with historical skill-commit detection.
- **Skip the trailer** when any reachable `CLAUDE.md` forbids it. Detection: case-insensitive grep for `co-authored-by` across the workdir's `CLAUDE.md`, any ancestor `CLAUDE.md` walking up to `/`, and `~/.claude/CLAUDE.md` — any hit ⇒ skip the trailer (the HTML marker alone is sufficient). The heuristic is intentionally conservative — a false positive only omits a redundant trailer, while a false negative would violate a documented policy. One-shot detection:

  ```
  grep -liE "co-authored-by" <reachable-CLAUDE-md-paths> 2>/dev/null | head -1
  ```

Never reset an issue that already has a `status:in-progress` or `status:in-review` label. Resume.

## Phase 4: Handle state

> **Run Phase 5 escape-hatch checks first, before executing any handler below.** Phase 5's hard stops dominate state derivation.

### `pending` → `implementing`

1. Add `status:in-progress` label: `gh issue edit <n> --repo <owner>/<repo> --add-label status:in-progress`. (Confirm the label exists; create it with `gh label create` if missing — should already exist if `scaffold-sub-issues-gh` set up the repo.)
2. Write a start comment: `gh issue comment <n> --repo <owner>/<repo> --body '<!-- ship-issue:event:started --> 🚢 ship-issue-gh started.'`
3. `cd` to the resolved workdir. Pull latest `main`/`master`. **Derive the branch name** from the issue: `<n>-<kebab-title>` where `<title>` is lowercased, non-alphanumerics replaced with `-`, repeated `-` collapsed, leading/trailing `-` trimmed, truncated to 60 chars. ASCII-only — strip diacritics. Example: issue #42 "Add Avatar primitive" → `42-add-avatar-primitive`. Create the branch from `main`.
4. Read the full issue body. Implement against the acceptance criteria. Run the repo's local checks (read `package.json` scripts or an existing CLAUDE.md for the correct commands). After local checks pass, run the **UI-reachability check** (defined below) — ensures the change is reachable from the existing UI, or that the issue carries an explicit note for human validators.
5. Commit with a descriptive body explaining the *why*. Follow the **Skill-commit marker** rule (Phase 3 supporting rules): always include a `<!-- ship-issue:commit -->` HTML comment in the commit body; include a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer unless a reachable `CLAUDE.md` forbids it.
6. Push the branch.
7. Open the PR using `gh pr create`. The body **must** include `Closes <owner>/<repo>#<n>` (use the fully-qualified form even for same-repo, so cross-repo parent linking is consistent). This triggers GitHub's auto-close on merge.
8. Swap labels: remove `status:in-progress`, add `status:in-review`. `gh issue edit <n> --remove-label status:in-progress --add-label status:in-review`.
9. State becomes `pr-open`. Return — the `/loop` harness will wake again in 6 minutes.

#### UI-reachability check (referenced by `pending → implementing` step 4 and `implementing (resume)`)

After implementing and running local checks, scan the diff for new files under conventional UI-surface paths:

- `src/pages/**` (Next.js Pages Router, Astro, Nuxt)
- `pages/**` at repo root (older Next.js, similar)
- `src/routes/**` and `routes/**` (SvelteKit, SolidStart, Remix, TanStack Router)
- `app/**` paired with a framework router (Next.js App Router, Remix v2)
- `src/views/**` (Vue / older conventions)
- Framework-specific equivalents — use the same heuristic: any path the framework's routing convention treats as a user-reachable route.

**If at least one new UI-surface file was added**, take exactly one of the following actions before opening the PR:

a. **Wire an entry-point.** Add a link in the existing nav, mark up an index/landing page to reference the new surface, or otherwise ensure a human navigating the existing UI can reach the new surface without knowing the URL out-of-band.

b. **Inline a validation note.** If the surface is deliberately orphan (admin-only utility route, deep-link debug page, intentionally-unlinked) or the framework lacks a natural entry-point, post a `<!-- ship-issue:note:reachability -->` comment on the issue stating exactly how a human should reach the new surface during `## Validation` — e.g. *"feature is not reachable from existing UI; navigate to `/foo` directly to verify."*

**Pure-backend changes** (only files outside the UI-surface conventions — `src/lib/`, `src/api/`, `src/server/`, `internal/`, library code, infra, migrations, docs) **skip this step entirely.** No entry-point needed; no validation note required.

**Detection is heuristic** and may misfire — when ambiguous (a path that matches a UI-surface pattern but isn't actually user-reachable, e.g. a `pages/_app.tsx` framework shell, a non-route module under `app/`, or a route gated by feature-flag), err toward (b) — write the validation note rather than fake-wiring an entry-point. The cost of an unnecessary note is one extra comment; the cost of a missing note is a manual validation that quietly skips the new surface.

### `implementing` (resume)

Same as `pending → implementing` but:

- Check for an existing local branch matching the derived name. If present, continue there; otherwise create it.
- Do not re-add the `status:in-progress` label if it's already present.

### `pr-open`

`pr-open` means: an open PR exists, no new reviewer comments, no failing checks. There's nothing to do on this wake.

1. Print a one-line "still waiting" summary: the PR URL, the last skill-commit SHA, and the timestamp.
2. Return.

Do **not** push new commits, re-classify, or re-evaluate CI state here. All classification lives in Phase 3.

### `fixing`

Entered from Phase 3 row 3 (new review comments) or row 3a (failing assertion CI check). Invoked *by* Phase 5 sub-phase B step 4 — Phase 5 dispatches into this handler and observes whether execution reaches step 6.

1. Use the check statuses and review comments gathered in Phase 3. For each failing assertion check, fetch its **log output** now (`gh run view <run-id> --log-failed --repo <owner>/<repo>`). Classify each item:
   - **code-review-bot finding** (author = the bot account or the well-known comment prefix).
   - **Human reviewer comment.**
   - **Failing assertion-style CI check** — drive the fix from the check's output.
   - **Scope-creep comment** (request for functionality outside the issue body's acceptance criteria) → `blocked-user` with reason `scope-creep`.
   - **@-mention of Claude** → treat as a direct user instruction; read it. If it needs clarification → `blocked-user` with reason `user-mention-ambiguous`. Otherwise act on it.
2. Make the fix in the workdir.
3. **Before committing, re-run the repo's local checks**. Interpret results identically to the Linear sibling: passes → step 4; command-fail → `blocked-user`; new regression → `blocked-user`; same failure → back to step 2.
4. Commit with a descriptive message referencing the thread / reviewer / check. Follow the **Skill-commit marker** rule (Phase 3 supporting rules) — same marker conventions as `pending → implementing` step 5. Push.
5. On each comment thread, reply with a short note referencing the fix commit SHA: `Fixed in abc1234.` Use `gh api /repos/<owner>/<repo>/pulls/<pr>/comments/<comment-id>/replies -f body=<text>` for inline review threads, or `gh pr comment <pr>` for top-level comments.
6. Return — the next wake's Phase 3 will re-derive state. **Reaching this step is the success signal to Phase 5.**

**Do not write or modify `<!-- ship-issue:failcount:... -->` comments in this handler.** Phase 5 owns the counter lifecycle.

### `merged`

Reaching this handler means Phase 3's row 1a did not apply.

1. Close the issue with `--reason completed`: `gh issue close <n> --repo <owner>/<repo> --reason completed`. (GitHub's auto-close from the merged PR's `Closes` trailer may have already closed it — that's fine; the call is idempotent and we still write the comment below.)
2. Write a terminal comment: `gh issue comment <n> --repo <owner>/<repo> --body '<!-- ship-issue:event:merged --> ✅ Merged: <PR URL>.'`
3. **Compact-on-merge** (skip in no-compact mode): if at least one non-terminal item remains in the queue, print the compaction prompt as the last output of this wake, after the Phase 8 block — `🗜 Sub-issue <ref> merged. Run /compact now to free context before picking up <next-ref>.` Trigger boundary, safety rationale, and exact rules live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md). At most once per wake; never when the merged item was the last (the loop is about to self-cancel).
4. Advance to the next item in the list.

### `blocked-verify`

Pre-Phase C behavior — auto-verify is **Planned** (Phase C — `/verify-ticket`):

1. Inline the `## Validation` text from the issue body into a `blocked-user` comment so a human can run it manually.
2. Transition to `blocked-user` with reason `awaiting-manual-verification`. Leave the issue **open** with `status:in-review` — closing now would skip the verification gate.

### `blocked-user`

1. Write a comment explaining what's blocking and what input is needed: `gh issue comment <n> --repo <owner>/<repo> --body '<!-- ship-issue:event:blocked --> 🛑 Blocked: <reason>. Needs: <ask>.'`
2. Slack ping is **Planned** for Phase B.
3. Leave `status:*` label at its current value — do not transition. If `blocked-user` fires during `implementing`, label is `status:in-progress` and stays there. If during `pr-open` / `fixing`, label is `status:in-review` and stays there. The work isn't regressing; it's waiting on a human.
4. Halt the `/loop` — print the reason clearly.

### `failed`

1. Write a comment with the failure reason and any relevant URLs: `<!-- ship-issue:event:failed --> ❌ Failed: <reason>.`
2. Close the issue with `--reason not_planned`: `gh issue close <n> --repo <owner>/<repo> --reason not_planned`. Remove any `status:*` label.
3. Halt.

## Phase 5: Escape hatches (hard stops)

Run immediately after Phase 3, before any Phase 4 handler. Evaluated against the data already gathered in Phase 3 — do not re-fetch.

### Three-strikes CI counter

Owned entirely by this phase. Same contract as the Linear sibling — Phase 3 and Phase 4 never read or write `<!-- ship-issue:failcount:... -->` comments; only Phase 5 does.

**Sub-phase A: reset scan — runs first, unconditionally.**

1. List all existing `<!-- ship-issue:failcount:<key>=N -->` comments on the issue where `N > 0` (via the comments fetch from Phase 3).
2. For each such `<key>` (e.g. `github:ci/test`): look at the current CI data from Phase 3. If a check with exactly that name exists and has `conclusion=success`, append a `<!-- ship-issue:failcount:<key>=0 -->` comment to record the reset.
3. A key with no matching check is **not** reset — leave it. The counter only resets on an observed pass.

**Sub-phase B: increment / hard-stop — conditional on this wake's state.**

Fire **once per wake**, in this order:

1. If Phase 3's derived state is not `fixing`, stop. If `fixing` but no completed CI check has `conclusion=failure` of the assertion type (after per-check reclassification), also stop.
2. Identify failing assertion check(s). For each:
   - Key: `github:<check-name>` (no platform prefix variation needed — this skill is GitHub-only).
   - Read the most recent `<!-- ship-issue:failcount:<key>=N -->` comment. If none, `N = 0`.
3. If `N + 1 >= 3` for **any** failing assertion key → **override** Phase 3's state to `failed` with reason `ci-three-strikes:<key>`. Run the `failed` handler and halt.
4. Otherwise, hand control to the `fixing` handler and let it run to completion. **After** the `fixing` handler reaches its step 6 (the success signal), append a single new `<!-- ship-issue:failcount:<key>=N+1 -->` comment per currently-failing assertion key. Never increment twice in one wake. If `fixing` escapes to `blocked-user`/`failed` before reaching step 6, do **not** write any increment.

### Rebase against base — attempt-and-gate

When the branch is detected as behind `main`/`master` (typically after a parent or sibling PR merges into the base during a parallel epic run), attempt an automatic rebase before escalating.

1. `git fetch origin && git rebase origin/<base>`.
2. **Conflict markers present** → `git rebase --abort`. Transition to `blocked-user` with reason `rebase-needs-human`. The marker comment lists the conflicted file paths so the human can resolve locally and push.
3. **Rebase clean (no markers)** → run the project's gates — the same local checks Phase 4's handlers run (`pnpm typecheck && pnpm test` or whatever the repo's `package.json` scripts / CLAUDE.md defines).
4. **Gates pass** → `git push --force-with-lease`. Post `<!-- ship-issue:rebase:auto -->` as a **marker-only** comment — the marker is the entire comment body, no trailing prose. Matches the convention of the other `<!-- ship-issue:* -->` markers (e.g. `<!-- ship-issue:commit -->`): downstream skills (`/abc:review-sweep` health pre-pass and the CI-repair pre-pass) grep for the marker as a yes/no signal, and free-form prose breaks the match across revisions. The rebase SHA range is already captured in the commit log for forensic reading. If a human-readable timeline note is also wanted, post it as a *separate* PR comment that does NOT contain the marker so the two signals stay decoupled. Re-enter Phase 3 on the next wake.
5. **Gates fail** → `git rebase --abort`. Transition to `blocked-user` with reason `rebase-clean-but-tests-failed`. The marker comment summarises the failing gate output (top ~20 lines is enough).
6. The **self-cheating hard stop** below applies verbatim inside this flow. No `--no-verify`, no `.skip()`-ing tests, no `// @ts-expect-error` to silence a failure, no widening types — even when auto-resolving. If the only way to make gates pass is to delete or weaken an assertion, abort and escalate via step 5.

The legacy `failed: rebase-conflict-needs-human` reason is **no longer emitted**. Mechanical rebase failures are recoverable — the cron stays armed, the human nudges, the worker continues — so they belong on the `blocked-user` axis, not `failed`. `failed` is reserved for self-cheating and hard correctness walls (see below and the three-strikes counter above).

### Self-cheating hard stop (the most important rule in this skill)

If the skill catches itself about to bypass a failing check rather than fix it — deleting a failing assertion, adding `--no-verify` to a commit, widening a type to suppress an error, wrapping a line in `// @ts-expect-error`, `.skip()`-ing a failing test, commenting out a lint rule that was firing, `eslint-disable`-ing a violation — **hard stop → `failed`**. Write the attempted-cheat into the issue comment so the human can see exactly what the skill was about to do.

## Phase 6: Blocked-user triggers

Soft stops — the loop pauses, the user resumes:

- Review comment requests scope outside the issue's acceptance criteria.
- Same code-review-bot **rule ID** fires twice in a row after a fix commit.
- CI fails in a non-assertion way (env missing, secrets unavailable, dependency resolution error).
- Merge conflict with `main` after the attempted auto-rebase (see Phase 5 § Rebase against base — attempt-and-gate). Conflict markers or red gates after a clean rebase both escalate as `blocked-user`, not `failed`.
- User @-mentions Claude on the PR or in an issue comment.
- Any repo-discovery condition from Phase 1.

## Phase 7: Stop conditions

The loop halts when any of:

- All items reach `merged`.
- Any item enters `blocked-user`.
- Any item enters `failed`.
- User @-mentions Claude on a PR or comments `cancel` on the issue.

**In every terminal case**, before returning, the skill calls `CronDelete` on its own `/loop` entry via the cron-entry match rule defined in Phase 0.5. If `CronDelete` fails, print a note but continue — the terminal comment + output are the authoritative surface.

## Phase 8: Output contract (every wake)

Print a concise block:

```
/ship-issue-gh wake <timestamp>

Items: <N>
  [merged]      <owner>/<repo>#42  <PR URL>
  [pr-open]     <owner>/<repo>#43  <PR URL>    (no new comments since <sha>)
  [pending]     <owner>/<repo>#44
  [blocked]     <owner>/<repo>#45  awaiting-manual-verification

Working: <owner>/<repo>#43
Next wake: /loop 6m /ship-issue-gh <original-arg>
```

Keep the output short on no-op wakes.

## Notes on persistence

**Nothing is persisted locally.** All skill-authored state lives in GitHub issue comments using the marker format in `../scaffold-sub-issues-gh/github-conventions.md`. Closing the terminal mid-loop is safe; re-running `/ship-issue-gh <same-arg>` derives state fresh.

If a counter comment or event comment needs updating, **append a new comment** rather than editing the existing one — comment history is the audit trail. GitHub doesn't expose edit history through `gh api` reliably, so an edited marker is worse than an appended one.

## Planned follow-ups (not implemented here)

- **Slack ping on `blocked-user`** → Phase B. Placeholder only.
- **Auto-verify via `/verify-ticket`** → Phase C.
- **Auto-stacked PRs** for sub-tasks touching the same files → v1 serialises.
- **`gh issue develop`** integration for formally linking the branch — v1 derives the branch locally; a future iteration can call `gh issue develop --name <derived>` for richer GitHub UI linking.
