---
name: ship-issue-gh
description: GitHub · GitHub-Issues sibling of /abc:ship-issue. Drives a GitHub issue (or list, or parent with task-list children) from `pending` to `merged` through the implement → PR → address-review → merge loop. Emulates Linear's state machine on top of GitHub Issues using the label conventions documented in scaffold-sub-issues-gh/github-conventions.md. TRIGGER when the user says "/ship-issue-gh <owner>/<repo>#<n>", asks to ship/land/drive a GitHub issue, or wants Claude to take a GitHub-tracked ticket through review to merge. Also trigger when resuming work on a GitHub issue with an open PR and pending reviewer comments. Self-arms its own `/loop` — the user invokes once and walks away.
argument-hint: "<owner>/<repo>#<n> | #<n> (in a git repo) | <owner>/<repo>#<n>,<owner>/<repo>#<m> | <owner>/<repo>#<parent> (walks task-list children) | milestone:<owner>/<repo>/<num-or-name>"
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

> The architecture (state machine, blocked-user triggers, escape hatches, locked decisions) lives in `DESIGN.md` alongside this file. The label scheme + marker comments + task-list fence live in `../scaffold-sub-issues-gh/github-conventions.md`. Read both before changing behavior. This file is the operational procedure.

---

## Phase 0: Parse input

Normalize `$ARGUMENTS` into an ordered list of fully-qualified `<owner>/<repo>#<n>` IDs.

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

The user's order is respected. The skill does not re-prioritise.

## Phase 0.5: Self-arm the loop (load-bearing)

Identical contract to the Linear sibling's Phase 0.5 — the skill arms its own `/loop` so the user invokes once and walks away. Runs on every wake, including loop-triggered ones; the idempotent match below makes subsequent wakes a no-op.

### Cron-entry match rule

Defined once here, referenced by name in Phase 7's self-cancel — these two checks must stay in lockstep.

> A `CronList` entry **matches** this invocation when its command string contains the substring `/ship-issue-gh <raw-arg>` **followed by a word boundary** — the next character (if any) must NOT be alphanumeric, `-`, `,`, `/`, or `#`. This prevents `/ship-issue-gh foo/bar#1` from false-matching an entry for `/ship-issue-gh foo/bar#10` (prefix) or `/ship-issue-gh foo/bar#1,foo/bar#2` (comma continuation). The `/` and `#` exclusions are GitHub-ID specific; the Linear sibling's rule doesn't need them because Linear IDs lack those characters. Boundary check works whether `CronList` reports the wrapped form `/loop 6m /ship-issue-gh <raw-arg>` or the inner `/ship-issue-gh <raw-arg>`.

### Arm check

1. Call `CronList` to enumerate active scheduled tasks in the current session.
2. Apply the cron-entry match rule above to each entry.
3. If a match is found → no-op, proceed to Phase 1. This is the common path on loop-triggered wakes.
4. If no match → the user invoked `/ship-issue-gh <raw-arg>` directly without a `/loop` wrapper (the expected first-invocation case). Invoke `Skill(skill: "loop", args: "6m /ship-issue-gh <raw-arg>")` to arm the cron, then proceed to Phase 1.

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

**Defining "the last skill commit"** (used in rows 3, 3a, 3b, 4): the most recent commit on the PR branch whose message contains a literal `Co-Authored-By: Claude` trailer. Find it with:

```
git -C <workdir> log <pr-branch> --grep="Co-Authored-By: Claude" -1 --format="%H %ai"
```

If no such commit exists on the branch, treat **all** open review comments as new.

Never reset an issue that already has a `status:in-progress` or `status:in-review` label. Resume.

## Phase 4: Handle state

> **Run Phase 5 escape-hatch checks first, before executing any handler below.** Phase 5's hard stops dominate state derivation.

### `pending` → `implementing`

1. Add `status:in-progress` label: `gh issue edit <n> --repo <owner>/<repo> --add-label status:in-progress`. (Confirm the label exists; create it with `gh label create` if missing — should already exist if `scaffold-sub-issues-gh` set up the repo.)
2. Write a start comment: `gh issue comment <n> --repo <owner>/<repo> --body '<!-- ship-issue:event:started --> 🚢 ship-issue-gh started.'`
3. `cd` to the resolved workdir. Pull latest `main`/`master`. **Derive the branch name** from the issue: `<n>-<kebab-title>` where `<title>` is lowercased, non-alphanumerics replaced with `-`, repeated `-` collapsed, leading/trailing `-` trimmed, truncated to 60 chars. ASCII-only — strip diacritics. Example: issue #42 "Add Avatar primitive" → `42-add-avatar-primitive`. Create the branch from `main`.
4. Read the full issue body. Implement against the acceptance criteria. Run the repo's local checks (read `package.json` scripts or an existing CLAUDE.md for the correct commands).
5. Commit with a descriptive body explaining the *why*. Add a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer — this exact string, so the Phase 3 "last skill commit" lookup is reliable.
6. Push the branch.
7. Open the PR using `gh pr create`. The body **must** include `Closes <owner>/<repo>#<n>` (use the fully-qualified form even for same-repo, so cross-repo parent linking is consistent). This triggers GitHub's auto-close on merge.
8. Swap labels: remove `status:in-progress`, add `status:in-review`. `gh issue edit <n> --remove-label status:in-progress --add-label status:in-review`.
9. State becomes `pr-open`. Return — the `/loop` harness will wake again in 6 minutes.

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
4. Commit with a descriptive message referencing the thread / reviewer / check, plus the standard `Co-Authored-By: Claude <noreply@anthropic.com>` trailer. Push.
5. On each comment thread, reply with a short note referencing the fix commit SHA: `Fixed in abc1234.` Use `gh api /repos/<owner>/<repo>/pulls/<pr>/comments/<comment-id>/replies -f body=<text>` for inline review threads, or `gh pr comment <pr>` for top-level comments.
6. Return — the next wake's Phase 3 will re-derive state. **Reaching this step is the success signal to Phase 5.**

**Do not write or modify `<!-- ship-issue:failcount:... -->` comments in this handler.** Phase 5 owns the counter lifecycle.

### `merged`

Reaching this handler means Phase 3's row 1a did not apply.

1. Close the issue with `--reason completed`: `gh issue close <n> --repo <owner>/<repo> --reason completed`. (GitHub's auto-close from the merged PR's `Closes` trailer may have already closed it — that's fine; the call is idempotent and we still write the comment below.)
2. Write a terminal comment: `gh issue comment <n> --repo <owner>/<repo> --body '<!-- ship-issue:event:merged --> ✅ Merged: <PR URL>.'`
3. Advance to the next item in the list.

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

### Rebase / merge-conflict hard stop

If a rebase against `main`/`master` after a parent-PR merge fails and auto-resolution would clearly be wrong → `failed` with reason `rebase-conflict-needs-human`.

### Self-cheating hard stop (the most important rule in this skill)

If the skill catches itself about to bypass a failing check rather than fix it — deleting a failing assertion, adding `--no-verify` to a commit, widening a type to suppress an error, wrapping a line in `// @ts-expect-error`, `.skip()`-ing a failing test, commenting out a lint rule that was firing, `eslint-disable`-ing a violation — **hard stop → `failed`**. Write the attempted-cheat into the issue comment so the human can see exactly what the skill was about to do.

## Phase 6: Blocked-user triggers

Soft stops — the loop pauses, the user resumes:

- Review comment requests scope outside the issue's acceptance criteria.
- Same code-review-bot **rule ID** fires twice in a row after a fix commit.
- CI fails in a non-assertion way (env missing, secrets unavailable, dependency resolution error).
- Merge conflict with `main` needs judgment.
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
