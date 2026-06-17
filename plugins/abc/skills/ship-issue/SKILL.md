---
name: ship-issue
description: Linear · Drives a Linear issue (or list, or parent with sub-issues) from Backlog to Done through the implement → PR → address-review → merge loop. TRIGGER when the user says "/ship-issue TICKET-ID", asks to ship/land/drive/autoland a ticket, or wants Claude to take a Linear issue through review to merge. Also trigger when resuming work on a ticket with an open PR and pending reviewer comments. Supports GitHub + GitLab and multi-repo parent issues via `repo:` Linear labels. Self-arms its own `/loop` — the user invokes once and walks away.
argument-hint: "TICKET-ID | https://linear.app/.../TICKET-ID | ID1,ID2,ID3 | PARENT-ID | milestone:UUID [--no-compact]"
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
  - Bash(git branch:*)
  - Bash(git rebase:*)
  - Bash(git -C * remote get-url *)
  - Bash(git -C * log *)
  - Bash(gh pr:*)
  - Bash(gh api:*)
  - Bash(gh auth status:*)
  - Bash(gh run:*)
  - Bash(glab mr:*)
  - Bash(glab ci:*)
  - Bash(glab auth status:*)
  - Bash(cd:*)
  - Bash(ls:*)
  - Bash(pwd:*)
  - Bash(pnpm:*)
  - Bash(npm:*)
  - Bash(npx:*)
  - Bash(yarn:*)
  - Bash(node:*)
  - mcp__claude_ai_Linear__get_issue
  - mcp__claude_ai_Linear__list_issues
  - mcp__claude_ai_Linear__save_issue
  - mcp__claude_ai_Linear__list_comments
  - mcp__claude_ai_Linear__save_comment
  - mcp__claude_ai_Linear__list_milestones
---

Drive a Linear issue (or ordered list of issues, or parent with sub-issues) from **Backlog** to **Done** through the implement → open-PR → address-review → merge loop. Platform-agnostic: GitHub via `gh`, GitLab via `glab`. Stateless across sessions — Linear, GitHub, and GitLab are the sources of truth.

**Usage:** `/ship-issue <arg>` — the skill self-arms its own `/loop`. Invoke once and walk away.

Where `<arg>` is one of:

- A single ticket: `PROJ-88`
- A Linear URL: `https://linear.app/<workspace>/issue/PROJ-88`
- A comma-separated ordered list: `PROJ-65,PROJ-66,PROJ-67`
- A parent issue ID — sub-issues are resolved and walked in Linear's default order
- A project milestone: `milestone:<uuid>` — expands to non-terminal issues in that milestone, ordered by `createdAt` ascending

Any shape may carry a trailing `--no-compact` flag to suppress the compact-on-merge prompt — see [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

> The architecture (state machine, blocked-user triggers, escape hatches, locked decisions) lives in `DESIGN.md` alongside this file. Read that first if you're changing behavior. This file is the operational procedure.

---

## Phase 0: Parse input

Normalize `$ARGUMENTS` into an ordered list of Linear ticket IDs. The branch taken depends on the shape of the arg:

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-on-merge prompt (Phase 4 § `merged`) is skipped at every trigger boundary. Contract and rationale live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md). Shape detection below runs on the flag-stripped string.

### Shape detection (in order, first match wins)

1. **Starts with `milestone:`** → milestone expansion (below).
2. **Is a Linear issue URL** (`https://linear.app/<org>/issue/<id>`) → strip prefix, extract `TEAM-N` identifier, continue as single ID.
3. **Is a Linear project URL** (`https://linear.app/<org>/project/<slug>/...`) — these are project overview / issues / triage URLs that don't point at a single ticket:
   - If the URL contains a `#milestone-<uuid>` fragment (e.g. `.../project/foo/overview#milestone-abc-123`), extract the UUID and route through the **milestone expansion** path below, as if the user had typed `milestone:<uuid>`. The fragment regex is `#milestone-([0-9a-fA-F-]+)` (UUID may contain hex digits and dashes).
   - Otherwise (no fragment, or a fragment that isn't `milestone-<uuid>`) → `blocked-user` with reason `project-url-without-milestone-fragment`. The block message lists the four supported shapes: a single ticket (`PROJ-88`), a Linear issue URL, a comma-separated list, and a milestone (`milestone:<uuid>` or a project URL with a `#milestone-<uuid>` fragment). Do not proceed to Phase 0.5 — no cron arming.
4. **Contains a comma** → split on commas → comma-list flow.
5. **Otherwise** → single-ID flow; check for sub-issues via `list_issues` with `parentId=<id>`; if present, replace with the sub-issue IDs in the API's return order; if none, keep the single ID.

### Milestone expansion

For `milestone:<uuid>`:

1. **Resolve the milestone to its project.** Call `mcp__claude_ai_Linear__list_milestones` (no project filter needed — we're matching by UUID) and find the entry whose `id === <uuid>`. Extract its `project` reference. If no match:
   - → **`blocked-user`** with reason `milestone-not-found:<uuid>`. Do not proceed to Phase 0.5 — no cron arming.
2. **Fetch issues scoped to that project.** Call `mcp__claude_ai_Linear__list_issues` with `project=<resolved-project>`, `orderBy: createdAt` ascending, `limit: 250` (MCP max). If the response reports `hasNextPage: true`, paginate via `cursor` until exhausted. Scoping by project keeps this bounded — per-project issue counts are typically ≤ a few hundred.
3. **Client-side filter**:
   - Keep only issues where `projectMilestone.id === <uuid>`.
   - Drop terminal issues — anything with `statusType` of `completed` (Done) or `canceled`. We don't re-ship already-shipped tickets.
4. **Empty-list guard.** If the resulting list is empty (all issues in the milestone are already terminal, or the milestone has no issues):
   - → **`blocked-user`** with reason `milestone-no-open-tickets:<uuid>`. Do not proceed to Phase 0.5 — no cron arming. An empty-list loop would poll nothing forever.
5. The resulting ordered IDs become the ticket list. Phase 1 onward is unchanged.

**Ordering caveat** (document inline for the user on the first wake's output): ordering is `createdAt` ascending. This matches the usual "tickets created in work-order" convention. If the milestone has been manually reordered in Linear, the skill won't follow the manual reorder — the MCP doesn't expose `sortOrder` on issues. Pass a comma-separated list in the desired order as the workaround for reordered milestones.

### Raw-arg retention

Retain the **raw arg string** (as the user typed it — e.g. `PROJ-89,PROJ-90`, `milestone:<uuid>`, `PROJ-100`, NOT the expanded list) for the self-arming check in Phase 0.5. It's the match key for `CronList` and `CronDelete`. For milestone args specifically, this means one loop polls the same milestone across wakes — new issues added to the milestone mid-flight get picked up on the next wake's re-derivation without spawning a second loop.

A `--no-compact` flag is part of the raw arg string — it stays in the cron entry's command so the opt-out survives every subsequent wake (the skill persists nothing locally; the cron arg is the only carrier — see `../_shared/compact-on-merge.md` § `--no-compact`).

The user's order is respected. The skill does not re-prioritise.

## Phase 0.5: Self-arm the loop (load-bearing)

The skill arms its own `/loop` so the user invokes once and walks away. This phase runs on **every wake**, including loop-triggered ones — the idempotent match below makes subsequent wakes a no-op.

### Cron-entry match rule

Used by both this phase's arm check and Phase 7's self-cancel — these two checks must stay in lockstep. Defined in [`../_shared/cron-match.md`](../_shared/cron-match.md); this skill is the **`ship-issue`** consumer (`<boundary-class>` = alphanumeric, `-`, `,`; `/loop` interval `6m`).

### Arm check

1. Call `CronList` to enumerate active scheduled tasks in the current session.
2. Apply the cron-entry match rule above to each entry.
3. If a match is found → no-op, proceed to Phase 1. This is the common path on loop-triggered wakes.
4. If no match → the user invoked `<command-name> <raw-arg>` directly without a `/loop` wrapper (the expected first-invocation case). Invoke `Skill(skill: "loop", args: "6m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1.

**Match key is the full raw arg string.** Two separate invocations with different args → two independent loops. This is intentional: a second list (`/ship-issue PROJ-91`) shouldn't interfere with an in-flight one (`/ship-issue PROJ-89,PROJ-90`).

Proceed to Phase 1 in both cases — the first wake also does the work of the first iteration; arming the cron doesn't displace it.

## Phase 1: Resolve each item (platform + repo)

For **each** item in the list — including each sub-issue when the input was a parent — apply the per-item resolution rule:

1. Fetch the ticket via `mcp__claude_ai_Linear__get_issue` with `includeRelations: true`. Read `labels`.
2. Collect any label names starting with `repo:`.
3. Apply this decision table:

   | Count of `repo:` labels | Action |
   |---|---|
   | 0 | Use the current git repo of the invocation cwd. If cwd is not inside a git repo → `blocked-user`. |
   | 1 | Extract `<name>` from `repo:<name>`. Look for a subdirectory of cwd matching `<name>`. If missing → `blocked-user` with a note listing available subdirs. |
   | 2+ | `blocked-user` — one item resolves to at most one repo. |

4. Once the working directory is picked, detect the platform:

   ```
   git -C <workdir> remote get-url origin
     contains "github.com"    → platform=github, cli=gh
     contains "gitlab.<host>" → platform=gitlab, cli=glab
     anything else            → blocked-user (unknown platform)
   ```

5. Confirm the CLI is authed: `gh auth status` (GitHub) or `glab auth status --hostname <host>` (GitLab). Derive `<host>` from the `ABC_GITLAB_HOST` env var if set, else parse it from `git remote get-url origin`; fall back to bare `glab auth status` if no GitLab remote resolves. Never hardcode a GitLab hostname. If not authed, `blocked-user` with the auth command to run.

**Cache** the resolved `{workdir, platform, cli}` tuple per ticket for this invocation. Re-resolution on the next `/loop` wake is cheap and handles the case where the user added/removed a label mid-flight.

**Resolve the team's workflow-state names by `statusType`.** Linear teams can rename their workflow states ("In Progress" → "Building", "Done" → "Shipped"), **and the default workflow has two `started`-type states — `In Progress` and `In Review` — that `statusType` alone cannot tell apart.** `get_issue` returns only the ticket's *current* state, not the team's full state list, so build the map from the team's states: call `mcp__claude_ai_Linear__list_issues` scoped to the ticket's team and collect the **distinct `state` objects** seen (each carries `name`, `statusType`/`type`, and `position`). Group by `statusType` and resolve + cache:

- `started`, **lower `position`** → the working/in-progress state name (default `In Progress`) → `resolved_started_state`
- `started`, **higher `position`** → the review state name (default `In Review`) → `resolved_in_review_state` — this `position`-based split is what disambiguates the two `started` states; if the team has only one `started` state, both roles map to it
- `completed` → the done state name (default `Done`) → `resolved_completed_state`
- `canceled` → the canceled state name (default `Canceled`) → `resolved_canceled_state`

Fall back to the default name for any role not resolvable (team uses the defaults, `position` not exposed by the MCP, or no distinct state exists). Phase 3's row 0/row 5 and Phase 4's handlers reference these **resolved-state variables** (`resolved_started_state` / `resolved_in_review_state` / `resolved_completed_state` / `resolved_canceled_state`), not the literal strings.

## Phase 2: Pick the next item

Walk the list in order. For each item, derive its current state (Phase 3). The skill works on **one ticket at a time** — serialisation is deliberate (see `DESIGN.md` → open questions on stacked PRs; v1 is serial).

Skip items already in `merged`. Work the first non-terminal item. If any item is in `failed` or `blocked-user`, halt the whole loop — see Phase 7.

## Phase 3: Derive current state

### Data to gather

Gather, for the current ticket:

- Ticket state (via `mcp__claude_ai_Linear__get_issue`): status, description, labels, links/attachments.
- Skill-authored Linear comments (via `mcp__claude_ai_Linear__list_comments`). These use HTML-comment markers `<!-- ship-issue:<category>:<key>=<value> -->`. Retain the **full** non-marker comment bodies too — the cancel scan below reads them.
- All PRs/MRs linked to the ticket (via the Linear attachments/links, cross-referenced with `gh pr list --search <ticket-id>` or `glab mr list --search <ticket-id>`).
- For any open PR/MR: its review comments and its check-run / pipeline statuses (`gh pr view --json`, `gh pr checks --json name,state,bucket`, `glab mr view --output json`, `glab ci view --output json`), plus the **behind-base signal** — GitHub: `gh pr view <pr> --json mergeStateStatus` (a value of `BEHIND` means the branch is behind its base); GitLab: the diverged/behind commit counts from `glab mr view`. Phase 3.5's rebase trigger reads this signal.

**Cancel scan.** Scan the latest non-marker Linear comments for a standalone `cancel` — case-insensitive, where the whole comment body (or its first line) trimmed equals `cancel`. On a match → terminal halt: derive `failed` with reason `cancel-requested` and run Phase 7's stop flow (CronDelete). A `cancel` buried mid-paragraph does **not** trigger — only a standalone-comment / first-line cancel.

**If any of these reads fail** (non-zero exit, timeout, partial/paginated result the skill can't reconcile, or an MCP error) → transition to `blocked-user` with reason `cannot-read-ticket-state:<tool>:<detail>`. Do not fall through to the table — an unknown state is not "no match found." This matters most for row 1a: silently treating a failed `list_comments` as "no `verify:passed` marker" would bypass the validation gate.

For CI checks specifically, classify by a status vocabulary unified with the GitHub sibling's `bucket` schema. **GitHub** (`gh pr checks --json name,state,bucket`): a check is **failing** when `bucket=fail`, **pending** when `bucket=pending`; `pass`/`skipping`/`cancel` are not failing. **GitLab** pipelines (`glab ci view`): a job is **failing** when its status is `failed`, **pending** when `running` or `pending`; `success` is not failing. Only the failing-bucket checks (GitHub `bucket=fail`, GitLab `failed`) drive rows 3a/3b.

### State table

Apply these rules **in order** — first match wins. Phase 3 is the single point of state decision; Phase 4 handlers act on the derived state, they do not re-derive it.

| # | Condition | Derived state |
|---|---|---|
| 0 | The ticket is already in a **terminal tracker state** (`statusType` of `completed` or `canceled`) AND **no merged PR/MR** is linked | In list/parent context: **skip** this item (move to the next). In single-ticket context: `blocked-user` (reason: `ticket-already-terminal`) |
| 1a | A PR/MR linked to this ticket is **merged** AND the ticket description has a `## Validation` section (see matching rule below) AND no `<!-- ship-issue:verify:passed -->` comment exists | `blocked-verify` |
| 1 | A PR/MR linked to this ticket is **merged** (and 1a does not apply) | `merged` |
| 2 | A PR/MR linked to this ticket is **closed but not merged** | `failed` (surface the closed-PR URL, halt) |
| 3 | An **open PR/MR** exists AND has review comments (human or code-review-bot) created *after* the last skill commit | `fixing` |
| 3a | An **open PR/MR** exists, no new review comments since the last skill commit, AND one or more CI checks are in the **failing bucket** (GitHub `bucket=fail`, GitLab `failed`) of the **assertion type** (unit test, lint, type check, code-review-bot check-run with findings) | `fixing` |
| 3b | An **open PR/MR** exists, no new review comments since the last skill commit, AND one or more CI checks are in the **failing bucket** of the **infra/env type** (secrets missing, dependency resolution failure, runner error, no test output at all) | `blocked-user` (reason: `ci-infra-failure:<check-name>`) |
| 4 | An **open PR/MR** exists, no new review comments, no failing-bucket CI checks | `pr-open` |
| 5 | No PR has ever existed, ticket is in a `started`-type state (default `In Progress` / `In Review`) | `implementing` (resume — do not reset) |
| 6 | No PR, no prior activity | `pending` |

Row 0 is **first-match-wins** and precedes row 1: a ticket whose `statusType` is `completed` (Done) or `canceled` with no merged PR/MR is already terminal and re-shipping it would be wrong — skip it in a list/parent walk, or block in single-ticket context so the human knows the ID points at a closed ticket. (`statusType` is resolved per Phase 1 — see the resolved-state caching rule.)

### Supporting rules

**Heading-match for row 1a's `## Validation`**: case-insensitive match on any heading at `##` level or deeper (so `##`, `###`, `####`) whose leading word is `Validation` — i.e., `## Validation`, `## Validation:`, `## Validation steps`, `### Validation checklist`, `## VALIDATION` all qualify. `## Validate` does not (different word). When the heading is ambiguous, **err on the side of row 1a** (i.e., transition to `blocked-verify`) rather than advancing to `merged` — the failure mode of a false positive is a human-run manual check; the failure mode of a false negative is a silently bypassed validation gate.

**Edge cases for rows 3a / 3b** — apply in this order:

1. **Classify each failing-bucket check per-check first**, before evaluating the table rows. For each failing-bucket check, decide: assertion-type (unit/lint/type/code-review-bot-with-findings) or infra-type (secrets, dep resolution, runner error, no test output). If a check's failure is ambiguous (timeout, opaque build failure, no discernible output), classify it as infra-type. Rationale: a false escalation is a minor interruption, but burning a three-strikes attempt on an infra failure wastes the counter and leaves the real issue invisible.
2. **After per-check classification, evaluate rows 3a / 3b against the post-classification set.** If any assertion-type check remains failing, row 3a fires (first-match-wins) and an accompanying infra failure is *not* independently surfaced that wake — it will re-surface on a later wake (once the assertion check clears, only infra remains, and row 3b fires). If *no* assertion-type check remains after step 1's reclassification (e.g. the only failing check was ambiguous and got reclassified to infra), row 3a does not fire; row 3b may.

**Stale-CI freshness guard (rows 3a/3b + three-strikes).** A failing-bucket check counts as failing only if its run targets the **current head SHA** of the PR/MR (GitHub: the check-run's `head_sha` matching the PR's `headRefOid`; GitLab: the pipeline's `sha` matching the MR's source-branch tip). A failure recorded against an older commit is **stale** — treat it as `pending`, not failing. This stops a fix-push from being scored against a not-yet-rerun check: the old failing run lingers until CI re-triggers on the new SHA, and counting it would mis-fire row 3a and burn a three-strikes attempt on a result that no longer reflects the branch.

**The "last skill commit" definition + the Skill-commit marker conventions** (used by rows 3/3a/3b/4 and referenced by name from Phase 4's commit steps) are defined in [`../_shared/skill-commit-marker.md`](../_shared/skill-commit-marker.md). This skill is the **`ship-issue`** consumer (`<pr-branch>` = the Linear `gitBranchName`).

Never reset a ticket that Linear shows as In Progress or In Review. Resume.

## Phase 4: Handle state

> **Run Phase 3.5 escape-hatch checks first, before executing any handler below.** Phase 3.5's hard stops dominate state derivation: if any condition there is met, transition to `failed` immediately and do not execute a Phase 4 handler on this wake. The three-strikes CI counter in particular must be evaluated against the latest check statuses before `pr-open` or `fixing` run.

> Handlers below reference Linear states by **resolved-state variable** (the per-team name cached in Phase 1 by `statusType`), shown with the default name in parentheses. A team that renamed its states still gets the right transition.

### `pending` → `implementing`

1. Transition Linear status to the resolved `started` state (default `In Progress`) via `mcp__claude_ai_Linear__save_issue`.
2. Write a Linear comment noting start: `<!-- ship-issue:event:started --> 🚢 ship-issue started.`
3. `cd` to the resolved workdir. Pull latest `main`/`master`. Create a feature branch from the ticket's `gitBranchName` (Linear provides this on the issue object).
4. Read the full ticket description. Implement against the acceptance criteria. Run the repo's local checks (`pnpm test`, `pnpm lint`, etc. — read `package.json` scripts or an existing CLAUDE.md for the correct commands). After local checks pass, run the **UI-reachability check** (defined below) — ensures the change is reachable from the existing UI, or that the ticket carries an explicit note for human validators.
5. Commit with a descriptive body explaining the *why*. Follow the **Skill-commit marker** rule (Phase 3 supporting rules): always include a `<!-- ship-issue:commit -->` HTML comment in the commit body (the primary signal for the Phase 3 "last skill commit" lookup); include a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer unless a reachable `CLAUDE.md` forbids it.
6. Push the branch.
7. Open the PR/MR using the platform CLI. Include a Linear reference so the issue auto-links — **but the choice of reference depends on the validation gate** (same `## Validation` heading-match rule as Phase 3 row 1a):
   - **No `## Validation` heading** in the ticket description → use a Linear Magic URL close word (e.g. `Closes PROJ-88`) so the merge auto-completes the issue.
   - **`## Validation` heading present** → **omit the magic close word**; use a non-closing reference instead (a plain `Linear: <issue-url>` line, which links the issue without auto-completing it on merge). This lets the worker — not the merge — control when the issue moves to the done state: the `merged` handler transitions it only after the `blocked-verify` gate passes. A magic close word would auto-complete the issue on merge *before* the next wake's row 1a could derive `blocked-verify`, turning the gate into a post-mortem (the `Closes`-trailer-races-the-validation-gate race documented in `DESIGN.md`).
8. Transition Linear to the resolved in-review state (default `In Review`). Record the PR URL via `save_issue`'s `links` field.
9. State becomes `pr-open`. Return — the `/loop` harness will wake again in 6 minutes.

#### UI-reachability check (referenced by `pending → implementing` step 4 and `implementing (resume)`)

Defined in [`../_shared/ui-reachability.md`](../_shared/ui-reachability.md). This skill is the **`ship-issue`** consumer: option (b)'s `<tracker-comment>` is a `<!-- ship-issue:note:reachability -->` Linear comment on the ticket; the artifact opened after the check is the PR/MR.

### `implementing` (resume)

Same as `pending → implementing` but:

- Check for an existing local branch matching the Linear `gitBranchName`. If present, continue there; otherwise create it.
- Do not re-run Linear status updates that are already set correctly.

### `pr-open`

`pr-open` means: an open PR exists, no new reviewer comments, no failing checks. There's nothing to do on this wake.

**This skill NEVER runs `gh pr merge` / `glab mr merge` — a human merges.** The skill drives the PR/MR to green-and-reviewed and then waits; the final merge is always a human action.

1. Print a one-line "still waiting" summary: the PR URL, the last skill-commit SHA, and the timestamp.
2. **Merge-nudge (idempotent, one-time).** If the PR/MR is **green-but-unmerged with review addressed** (all checks in the passing/neutral buckets, no unresolved review comments) **and the last skill commit is older than ~30 minutes** — use the `%ai` timestamp from the Phase 3 "last skill commit" lookup; the skill is stateless and keeps **no per-wake counter**, so the age of that commit (not a count of `pr-open` wakes) is the durable, re-run-safe trigger — and no `<!-- ship-issue:note:merge-nudge -->` marker comment already exists on the ticket, post one marker-only Linear comment: `<!-- ship-issue:note:merge-nudge -->` (body is the marker plus the one-line "PR green & review addressed — ready to merge"). The marker's own presence makes this a no-op on every later wake, so it never re-posts.
3. Return — the `/loop` harness will wake again in 6 minutes.

Do **not** push new commits, re-classify, re-evaluate CI state, or merge here. All classification lives in Phase 3; if a CI check flips to failure between wakes, the next wake's Phase 3 will derive `fixing` (row 3a) or `blocked-user` (row 3b).

### `fixing`

Entered from Phase 3 row 3 (new review comments) or row 3a (failing assertion CI check). This handler is invoked *by* Phase 3.5 sub-phase B step 4, not alongside it — Phase 3.5 dispatches into this handler and observes whether execution reaches step 6 below. The handler itself never reads or writes `failcount:<key>=N` comments; Phase 3.5 writes the increment only after observing a clean step-6 return. If this handler exits via `blocked-user` or `failed` before step 6, no increment is written for this wake.

1. Use the check statuses and review comments gathered in Phase 3 — do not call `gh pr checks` / `glab ci view` or the comments API again. For each failing assertion CI check, fetch its **log output** now (e.g. `gh run view <run-id> --log-failed`, or `glab ci trace <job-id>`); logs were not retrieved in Phase 3, and this log fetch is the only additional network call this handler performs. Classify each item:
   - **code-review-bot finding** — the comment author's login (or a recognizable bot comment prefix) matches the **review-bot allowlist**: resolve it from `~/.claude/review-bots.md` if that file exists (one bot login per line; blank lines and `#`-comments ignored), otherwise use the built-in default set (`dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`, and common code-review bots). An author matching neither the allowlist nor the default set is treated as a **human reviewer comment**, not a bot finding — never hardcode a specific employer's bot name here; it belongs in the user's local `~/.claude/review-bots.md`. See the README's *Review-bot allowlist* section for the file format.
   - **Human reviewer comment.**
   - **Failing assertion-style CI check** — drive the fix from the check's output.
   - **Scope-creep comment** (request for functionality outside the ticket's acceptance criteria) → `blocked-user` with reason `scope-creep`.
   - **@-mention of Claude** → **this handler is canonical for @-mentions.** Read it: an **actionable** mention (a concrete instruction the skill can carry out within the ticket's scope) → act on it here in `fixing`. An **ambiguous** mention, or a **redirect/cancel** mention → `blocked-user` with reason `user-mention-ambiguous`. (Phase 6 and Phase 7 defer to this rule — they do not flatly halt on every @-mention.)
2. Make the fix in the workdir.
3. **Before committing, re-run the repo's local checks** (the same commands from the `implementing` step). Interpret results:
   - All checks pass → proceed to step 4.
   - A check **command fails to run** (non-zero exit with no test output, command-not-found, runner crash) → `blocked-user` with reason `local-check-command-failed:<command>`. Do not commit, do not push.
   - A check **runs and reports a failure** that is *not* the one the fix was intended to resolve (a new regression in an unrelated area) → `blocked-user` with reason `local-check-regression:<failing-check>`. Do not commit, do not push.
   - A check still reports the failure the fix was intended to resolve → go back to step 2; the fix isn't done.
4. Commit with a descriptive message referencing the comment thread ID or the reviewer's ask. Follow the **Skill-commit marker** rule (Phase 3 supporting rules) — same marker conventions as `pending → implementing` step 5. Push.
5. On each comment thread, reply with a short note referencing the fix commit SHA: `Fixed in abc1234.`
6. Return — the next wake's Phase 3 will re-derive state from the new PR/CI reality. **Reaching this step is the success signal to Phase 3.5** (it's how Phase 3.5 step 4 knows the fix commit pushed cleanly and the counter can be incremented). If any earlier step transitioned to `blocked-user` or `failed`, execution never reaches here and Phase 3.5 does not write a failcount comment for this wake.

**Do not write or modify `<!-- ship-issue:failcount:... -->` comments in this handler.** Phase 3.5 owns the counter lifecycle.

### `merged`

Reaching this handler means Phase 3's row 1a did not apply (no `## Validation` gate, or the gate has already passed). No re-check here — Phase 3 is the single point of decision.

1. Transition Linear to the resolved `completed` state (default `Done`) via `save_issue`. Write a terminal comment: `<!-- ship-issue:event:merged --> ✅ Merged: <PR URL>.`
2. **Compact-on-merge** (skip in no-compact mode): if at least one non-terminal item remains in the queue, print the compaction prompt as the last output of this wake, after the Phase 8 block — `🗜 Sub-issue <ref> merged. Run /compact now to free context before picking up <next-ref>.` Trigger boundary, safety rationale, and exact rules live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md). Never fires when the merged item was the last (the loop is about to self-cancel).
3. **If the step-2 prompt fired, end the wake here** — return rather than working `<next-ref>` in this same wake; the next `/loop` wake re-derives state (the merged item is now skipped by Phase 2) and picks up `<next-ref>` fresh (safe per "Notes on persistence"). This is what gives the user a `/compact` opportunity at the boundary — same-wake continuation would surface the prompt only after `<next-ref>`'s work has already accumulated. Otherwise (no-compact mode, or no non-terminal items remain), advance to the next item in the list.

### `blocked-verify`

Pre-Phase C behavior — auto-verify is **Planned** (Phase C — `/verify-ticket`):

1. Inline the `## Validation` text into a `blocked-user` comment so a human can run it manually. **The comment MUST include the unlock instruction verbatim:** "post a comment containing exactly `<!-- ship-issue:verify:passed -->`, then re-run `/abc:ship-issue <arg>`". Without that line the human has no documented way to clear the gate, and the next wake will re-derive `blocked-verify` forever.
2. Transition to `blocked-user` with reason `awaiting-manual-verification`.

Post-Phase C (not implemented here): the skill would invoke `/verify-ticket <id>` and branch on the result.

### `blocked-user`

1. Write a Linear comment explaining what's blocking, which item, and what input is needed: `<!-- ship-issue:event:blocked --> 🛑 Blocked: <reason>. Needs: <ask>.`
2. Slack ping is **Planned** for Phase B. Until then, the Linear comment plus the terminal output is the surface.
3. Leave the Linear status at its current value — do not transition it. Crucially: if `blocked-user` fires during `implementing` (e.g. repo resolution fails, CLI auth missing, scope-creep detected while reading the ticket description), the status is the resolved `started` state (default `In Progress`), and that's where it stays. If it fires during `pr-open` / `fixing`, the status is the resolved in-review state (default `In Review`) and stays there. The work isn't regressing; it's waiting on a human.
4. Halt the `/loop` — print the reason clearly so the user sees it.

### `failed`

1. Write a Linear comment with the failure reason and any relevant URLs: `<!-- ship-issue:event:failed --> ❌ Failed: <reason>.`
2. Transition Linear to the resolved `canceled` state (default `Canceled`) (DESIGN.md §State machine).
3. Halt.

## Phase 3.5: Escape hatches (run before handlers)

Run immediately after Phase 3, before any Phase 4 handler — execution order matches reading order (3 → 3.5 → 4). Evaluated against the data already gathered in Phase 3 — do not re-fetch.

### Three-strikes CI counter

Defined in [`../_shared/three-strikes-counter.md`](../_shared/three-strikes-counter.md). This skill is the **`ship-issue`** consumer: `<failing-bucket>` = GitHub `bucket=fail` / GitLab `failed`; `<passing-bucket>` = GitHub `bucket=pass` / GitLab `success`; `<failcount-key>` = `<platform>:<check-name>` (e.g. `github:ci/test`, `gitlab:build/compile`).

### Rebase against base — attempt-and-gate

Defined in [`../_shared/rebase-attempt-and-gate.md`](../_shared/rebase-attempt-and-gate.md). This skill is the **`ship-issue`** consumer: `<behind-base-signal>` = GitHub `mergeStateStatus=BEHIND` / GitLab a non-zero behind/diverged commit count from `glab mr view`; `<command>` = `/abc:ship-issue`. The **self-cheating hard stop** below applies verbatim inside that flow.

### Self-cheating hard stop (the most important rule in this skill)

If the skill catches itself about to bypass a failing check rather than fix it — deleting a failing assertion so tests pass, adding `--no-verify` to a commit, widening a type to suppress an error, wrapping a failing line in `// @ts-expect-error`, `.skip()`-ing a test that was failing, commenting out a lint rule that was firing, `eslint-disable`-ing a violation to silence it — **hard stop → `failed`**. No self-healing, no "I'll come back and fix it properly," no silent retry. Write the attempted-cheat to the Linear comment so the human can see exactly what the skill was about to do.

## Phase 6: Blocked-user triggers

Soft stops — the loop pauses, the user resumes:

- Review comment requests scope outside the ticket's acceptance criteria.
- Same code-review-bot **rule ID** (finding-name, not severity or category) fires twice in a row after a fix commit. The precise comparison is the named rule — broader comparisons over/under-trigger.
- CI fails in a non-assertion way (env missing, secrets unavailable, dependency resolution error).
- Merge conflict with `main` after the attempted auto-rebase (see Phase 3.5 § Rebase against base — attempt-and-gate). Conflict markers or red gates after a clean rebase both escalate as `blocked-user`, not `failed`.
- An **ambiguous, or a redirect/cancel @-mention** of Claude on the PR → `blocked-user`. **Actionable** @-mentions are handled in the `fixing` handler (Phase 4), which is canonical for mentions — do not halt on every @-mention.
- Any repo-discovery condition from Phase 1 (missing / multiple / unresolvable `repo:` labels, unknown platform).

## Phase 7: Stop conditions

The loop halts when any of:

- All items reach `merged`. Print summary.
- Any item enters `blocked-user`. Print reason + what's needed.
- Any item enters `failed`. Print the URL/reason.
- An **ambiguous, or a redirect/cancel @-mention** of Claude on a PR (actionable mentions are handled in the `fixing` handler, not here).
- A standalone `cancel` comment on the ticket is detected by the Phase 3 cancel scan (case-insensitive, whole-comment-body or first line) → terminal halt.

**In every terminal case — blocked-user, failed, and all-merged alike** — before returning, the skill calls `CronDelete` on its own `/loop` entry so the cron stops immediately. CronDelete fires on **all** halts; the cron never stays armed past a halt. Identify the entry via the cron-entry match rule defined in Phase 0.5 (§ Cron-entry match rule): find the `CronList` entry, extract its job ID, and `CronDelete` it. The user should not have to run `/loop cancel` manually — that's part of the self-contained contract.

If `CronDelete` fails (entry already gone, job-ID not found, etc.), do not halt the stop flow — print a note ("couldn't auto-cancel the loop; run `/loop cancel` if it's still firing") and continue. The terminal print + Linear comment are still the authoritative surface.

## Phase 8: Output contract (every wake)

Print a concise block the user can scan at a glance:

```
/ship-issue wake <timestamp>

Items: <N>
  [merged]      PROJ-65  <PR URL>
  [pr-open]     PROJ-66  <PR URL>    (no new comments since <sha>)
  [pending]     PROJ-67
  [blocked]     PROJ-68  awaiting-manual-verification

Working: PROJ-66
Next wake: /loop 6m <command-name> <original-arg>
```

`<command-name>` is the captured slash-command name from Phase 0.5 (e.g. `/abc:ship-issue`), not a hardcoded literal — same convention as the self-arm string.

Keep the output short on no-op wakes — the idempotency contract makes per-wake verbosity expensive.

## Notes on persistence

**Nothing is persisted locally.** All skill-authored state lives in Linear comments using the marker format above. This is intentional — see `DESIGN.md` § Session-boundary behavior. Closing the terminal mid-loop is safe; re-running `/ship-issue <same-arg>` derives state fresh.

If a counter comment or event comment needs updating, **append a new comment** rather than editing the existing one — Linear comment history is the audit trail.

## Planned follow-ups (not implemented here)

- **Slack ping on `blocked-user`** → Phase B. Placeholder only.
- **Auto-verify via `/verify-ticket`** → Phase C. Currently all `## Validation` tickets escape to `blocked-user`.
- **Auto-stacked PRs** for sub-tasks touching the same files → see DESIGN.md § open questions. v1 serialises.
- **Cancellation mechanism** beyond `/loop cancel` (e.g. a `cancel` Linear comment) → see DESIGN.md § open questions.
