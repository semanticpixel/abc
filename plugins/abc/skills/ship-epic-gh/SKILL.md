---
name: ship-epic-gh
description: GitHub · GitHub-Issues sibling of /abc:ship-epic. Coordinator for a GitHub parent issue whose children live in a managed `## Sub-issues` task-list. Builds a dependency graph from `blocks:#N` / `blocked-by:#N` labels on the children, fires `/loop 6m /abc:ship-issue-gh <owner>/<repo>#<n>` per ready child (truly parallel via independent cron entries), gates blocked children until upstreams merge, aggregates status into the parent. Self-arms its own `/loop` — invoke once and walk away. TRIGGER when the user says "/ship-epic-gh <owner>/<repo>#<n>", asks to "ship this epic" against a GitHub parent, or wants to drive a multi-repo GitHub epic through merge in parallel.
argument-hint: "<owner>/<repo>#<n> [--no-compact]"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Read
  - Bash(pwd:*)
  - Bash(ls:*)
  - Bash(gh auth status:*)
  - Bash(gh issue view:*)
  - Bash(gh issue comment:*)
  - Bash(gh issue close:*)
  - Bash(gh pr list:*)
  - Bash(gh api:*)
---

# /abc:ship-epic-gh — Parallel multi-repo shipping coordinator (GitHub)

Drive a GitHub **parent issue** whose body holds a managed `## Sub-issues` task-list to all-merged by firing one `/loop 6m /abc:ship-issue-gh <owner>/<repo>#<n>` per **ready** child, gating children with unmet `blocked-by:*` labels, and aggregating status on the parent. Each worker (`/abc:ship-issue-gh`) is independent — they run in parallel via their own cron entries, survive session close, and use GitHub Issues as the single source of truth.

This skill is the **coordinator**. It does NOT implement code, open PRs, or run tests directly — those are the workers' jobs.

This is the GitHub-Issues sibling of [`/abc:ship-epic`](../ship-epic/SKILL.md). The two are deliberately parallel skills — pick by tracker, not auto-detect. The label scheme, task-list fence, and marker comments it depends on are documented in [`../scaffold-sub-issues-gh/github-conventions.md`](../scaffold-sub-issues-gh/github-conventions.md).

See [`DESIGN.md`](./DESIGN.md) for the architectural rationale + locked decisions specific to the GitHub case. This file is the operational procedure.

## Hard rules

- **Never** spawn a worker for a child that has an unmet `blocked-by:*` label. Wait for the upstream to reach `merged` first.
- **Never** halt the epic just because one worker hits `blocked-user`. Other workers can continue; the blocked one waits for the human.
- **Never** modify worker state directly (no edits to `<!-- ship-issue:* -->` comments on children). Workers own their own state machines.
- **Never** edit content outside the `<!-- ship-epic:sub-issues:start/end -->` fence in the parent body. User-authored prose stays untouched.
- **Always** self-cancel the epic's cron on terminal states (all merged, any failed). `/abc:ship-issue-gh` self-cancels its own cron per its Phase 7; this skill mirrors that contract at the epic level.
- If the parent has no managed `## Sub-issues` task-list → reject and point the user at `/abc:scaffold-sub-issues-gh` to create one (or `/abc:ship-issue-gh` for a single issue).
- If the dependency graph has a cycle → **Phase 5 § Dependency cycle (terminal)**: write `<!-- ship-epic:event:cycle -->` once (dedup against an identical prior marker), `CronDelete` the epic's own loop, and halt. Refuse to fire any workers.

## Phase 0: Parse input and self-arm

### Normalize the arg

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-on-merge prompt (Phase 4) is skipped, and the flag propagates to every worker fired in Phase 3. The flag stays in the **raw arg string** used for cron arming/matching, so the opt-out survives every subsequent wake. Contract and rationale live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

`$ARGUMENTS` is one of:

1. **`<owner>/<repo>#<n>`** — a GitHub parent issue ID.
2. **GitHub issue URL** (`https://github.com/<owner>/<repo>/issues/<n>`, optionally with Enterprise host) → extract `<owner>/<repo>#<n>`.

Anything else (Linear IDs, bare `#<n>`, milestone refs, comma-lists) → reject. This skill requires an explicit GitHub parent issue. For milestone-style "ship every issue in this collection," use `/abc:ship-issue-gh milestone:<owner>/<repo>/<num>` instead — that's the serial walker; the coordinator pattern needs a real parent for status aggregation.

**Auth pre-flight.** `gh auth status --hostname <host>` where `<host>` is derived from the parent's URL (defaults to `github.com`). If not authed → `blocked-user` with the auth command.

### Fetch parent and parse the task-list

1. `gh issue view <n> --repo <owner>/<repo> --json number,title,state,stateReason,labels,body`.
2. If `state=closed` and `stateReason=completed` → epic is already done. Emit a one-line "already merged" summary and exit (do not arm a loop).
3. Locate the `<!-- ship-epic:sub-issues:start -->` and `<!-- ship-epic:sub-issues:end -->` fence markers in the body. If either is missing → reject with: "Parent `<owner>/<repo>#<n>` has no managed `## Sub-issues` task-list. Run `/abc:scaffold-sub-issues-gh` against this parent first, or use `/abc:ship-issue-gh` for single-issue shipping."
4. Parse each `- [ ] <ref>` and `- [x] <ref>` line between the fences. Each `<ref>` is either `#<n>` (same-repo as parent) or `<owner>/<repo>#<n>` (cross-repo). Normalize to fully-qualified form. The `[x]`-completed entries are kept in the set — they'll be classified `merged` in Phase 2, not skipped at parse time (the worker may still need to be checked for terminal cleanup).

If the parsed child set is empty → reject: "Parent has an empty `## Sub-issues` task-list. Add children with `/abc:scaffold-sub-issues-gh` first."

### Self-arm the loop

#### Cron-entry match rule

Defined in [`../_shared/cron-match.md`](../_shared/cron-match.md); this skill is the **`ship-epic-gh`** consumer (`<boundary-class>` = alphanumeric, `-`, `,`, `/`, `#` — the `/` and `#` exclusions are GitHub-ID specific; `/loop` interval `10m`).

- If a matching entry exists → no-op, proceed to Phase 1.
- If no match → this is the **first wake**. Run the **single-session constraint** checks below before arming. If they pass, invoke `Skill(skill: "loop", args: "10m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1 — the first wake also does the work of the first iteration.

#### Single-session constraint (first wake only)

The coordinator is single-session: exactly one coordinator loop per parent. On the **first wake** (no matching cron yet — about to arm), before arming:

- **Live sibling coordinator.** If a recent `<!-- ship-epic:status -->` comment exists on the parent that **THIS session did not write**, suspect a live sibling coordinator already running in another session → `blocked-user` with reason `possible-duplicate-coordinator`. Do not arm a second loop.
- **Parent already serial-walked.** If `CronList` shows a **serial-walker** entry for this same parent — a worker cron of the form `ship-issue-gh <PARENT-ID>` (the namespace-aware worker cron-match rule applied to the *parent's* own ID, i.e. someone ran `/abc:ship-issue-gh <parent>` to walk the task-list serially) → refuse to start with reason `parent-already-serial-walked`. Coordinating in parallel while the parent is being walked serially would double-fire workers.

(On non-first wakes a matching coordinator cron exists, so these checks are skipped — they guard the initial arm only.)

10-minute cadence is intentional (longer than the 6-minute worker cadence): the coordinator only needs to react when a worker reaches `merged` (unblocks downstream) or terminal (`failed`/`blocked-user`). Both events surface in GitHub within seconds; 10-minute lag is acceptable.

### Derived worker command (defined once — referenced by Phase 2 in-flight match AND Phase 3 fire string)

**Do not hardcode `/abc:`.** Derive the worker command from the **captured coordinator `<command-name>`** so a coordinator invoked top-level fires a top-level worker, and a plugin-namespaced coordinator fires a same-namespace worker:

> `<worker-command>` = the captured `<command-name>` with its trailing skill name `ship-epic-gh` swapped to `ship-issue-gh`, preserving any namespace prefix verbatim. So `/abc:ship-epic-gh` → `/abc:ship-issue-gh`, and a top-level `/ship-epic-gh` → `/ship-issue-gh`.

#### Worker cron-match rule (the single match key)

The Phase 3 fire string and the Phase 2 `in-flight` match key **MUST be the same string** — they are defined here once and referenced from both. Firing `/loop 6m <worker-command> <id>` while classifying `in-flight` against a *different* substring (e.g. the hardcoded `/ship-issue-gh <id>`) is exactly the bug this fixes: the namespaced fire string `/abc:ship-issue-gh <id>` never matches a bare `/ship-issue-gh <id>` grep, so the coordinator never recognizes its own running workers and re-fires duplicates.

> A `CronList` entry is the **worker for child `<id>`** when its command string matches the **namespace-aware regex** (same shape as the epic's own cron-match rule, with the GitHub-ID boundary class):
>
> `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue-gh <id>(?![A-Za-z0-9_,/#-])`
>
> where `<id>` is the child's fully-qualified `<owner>/<repo>#<n>`. The optional `<plugin>:` prefix capture matches whatever namespace the worker was fired under (it is the same namespace as `<worker-command>`); the trailing negative-lookahead is the GitHub-ID boundary class (`/` and `#` excluded). This is the **same string** as the Phase 3 fire string's command portion — define it once here, reference it by name from both Phase 2 (`in-flight`) and Phase 5 (kill targeting).

## Phase 1: Build the dependency graph

For each child in the parsed set:

1. `gh issue view <n> --repo <owner>/<repo> --json number,state,stateReason,labels`.
2. Read labels matching `blocks:#<N>` or `blocked-by:#<N>` (same-repo) or `blocks:<owner>/<repo>#<N>` / `blocked-by:<owner>/<repo>#<N>` (cross-repo). Normalize all refs to fully-qualified form for graph nodes.
3. **Filter to in-set edges only.** If a `blocked-by:` label points to an issue NOT in our parsed child set, surface it as `external-blocker` for that child (Phase 2) — don't try to follow it.
4. Build adjacency lists: `blocksMap[id]: Set<id>`, `blockedByMap[id]: Set<id>`. Union both directions so a `blocks:#A` label on B and a `blocked-by:#B` label on A produce the same edge once.

Detect cycles via DFS. On cycle → go to **Phase 5 § Dependency cycle (terminal)** — refuse to fire any workers. Phase 5 owns the marker-dedup + `CronDelete` + halt; do not write the marker or fire workers here.

## Phase 2: Classify each child

Pull `CronList` once at the top of this phase — don't re-poll per child. First match wins:

| State | Condition |
|---|---|
| `merged` | `state=closed` AND `stateReason=completed` AND a `<!-- ship-issue:event:merged -->` comment from the worker exists; **and when the child body has a `## Validation` heading** (heading-match per the worker's row-1a rule), a `<!-- ship-issue:verify:passed -->` marker also exists. A closed-completed child lacking the `event:merged` marker is **not** yet `merged` — the worker may still be finishing its validation gate; classify it via a lower row this wake (typically `in-flight` if its cron is still running, else fall through) |
| `failed` | A `<!-- ship-issue:event:failed -->` comment from the worker exists (worker hit a hard stop) |
| `blocked-user` | The child's latest `<!-- ship-issue:event:blocked -->` marker is **not postdated** by a human (non-skill) comment or a `<!-- ship-issue:verify:passed -->` marker — child is still `state=open`. (See **Re-fire on human reply** below: if a human reply / verify marker *does* postdate the blocked marker, the child is **re-fireable**, not still-blocked — it classifies `ready` when blockers are satisfied.) |
| `external-blocker` | A `blocked-by:` label points to an issue outside our child set AND that referenced issue is not yet merged. Recorded only in the epic's `<!-- ship-epic:status -->` comment — never written as a comment on the child |
| `in-flight` | A `CronList` entry matches the **worker cron-match rule** for this child (Phase 0.5 § Worker cron-match rule — the same `(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue-gh <id>` namespace-aware key the Phase 3 fire string uses) |
| `dropped (human-canceled)` | `state=closed` AND `stateReason=not_planned` BUT **no** `<!-- ship-issue:event:failed -->` marker (a human canceled the issue directly — not a worker failure). Surface in the status comment as `dropped (human-canceled)`; **do not** count toward the all-stop halt (Phase 5 § Any child failed). The epic continues |
| `ready` | All in-set `blocked-by:*` upstreams are `merged`, AND no in-flight cron, AND `state=open` (not in any terminal state). Includes a **re-fireable** previously-blocked child (see **Re-fire on human reply**) |
| `waiting` | One or more in-set `blocked-by:*` upstreams not yet `merged` |
| `blocked-user: unclassifiable-child` | **Catch-all** — no row above matched. A child can never fall through the table silently; surface it as `blocked-user` with reason `unclassifiable-child` so a human looks at it |

**Re-fire on human reply (how a blocked child resumes).** No worker ever writes an `event:resumed` marker — there is no such marker. A `blocked-user` child resumes by the coordinator **re-firing its worker**. The rule: take the child's latest `<!-- ship-issue:event:blocked -->` marker. If a **human (non-skill) comment** or a `<!-- ship-issue:verify:passed -->` marker postdates it (`created_at` strictly later), the human has answered the block → treat the child as re-fireable: it classifies `ready` (if its blockers are satisfied and no worker cron is in-flight) and Phase 3 fires a fresh worker, which is what resumes it. If nothing postdates the blocked marker, the child is still `blocked-user` and waits.

**Read-failure rule.** Mirror the worker's rule (`/abc:ship-issue-gh` Phase 3): if **any** read this phase fails (non-zero exit, timeout, pagination the coordinator can't reconcile), **skip classifying that child this wake** — do not fall through to a wrong state (e.g. treating an unread comments list as "no blocked marker"). The child keeps its prior surfaced state until a clean read. If the **parent** itself is unreadable on **consecutive** wakes → `CronDelete` the epic's loop and halt (Phase 5 § Parent unreadable).

Re-derive fresh on every wake — nothing is persisted locally.

## Phase 3: Fire workers for ready children

For each child in `ready` state, fire the **derived `<worker-command>`** (Phase 0.5 § Derived worker command — never the hardcoded `/abc:` literal):

```
Skill(skill: "loop", args: "6m <worker-command> <owner>/<repo>#<n>")
```

The `<worker-command> <owner>/<repo>#<n>` portion is the **same string** the Phase 2 `in-flight` worker cron-match rule keys on — that is what lets the next wake recognize this worker as `in-flight` instead of re-firing it. (e.g. coordinator `/abc:ship-epic-gh` → `<worker-command>` is `/abc:ship-issue-gh`.)

In no-compact mode, append the flag so workers inherit the opt-out: `Skill(skill: "loop", args: "6m <worker-command> <owner>/<repo>#<n> --no-compact")` (see `../_shared/compact-on-merge.md` § `--no-compact`).

This kicks off the worker's first wake and arms its own cron. The coordinator does NOT wait — it returns and the worker runs independently.

**Do not fire** workers for children already `in-flight` (the worker's own Phase 0.5 cron-match would no-op anyway, but skip explicitly for clarity).

If multiple children are `ready` in the same wake, fire all of them — the workers run in parallel on independent cron entries.

## Phase 4: Aggregate status

### GitHub comment on the parent

Resolve each child's PR URL for the `Latest` column via `gh pr list --repo <owner>/<repo> --search "<child-ref>" --state all --json url,state,mergedAt` (take the most recent linked PR) — this is the only PR-discovery call the coordinator makes; it never fetches PR bodies or diffs.

Append (not edit) a single `<!-- ship-epic:status -->` comment on the parent with the current snapshot. The task-list checkboxes in the parent body auto-toggle when each child closes — GitHub manages that natively; the skill does not touch the body for this purpose:

```
<!-- ship-epic:status -->
Wake: 2026-05-17T18:30:00Z  (4 of 6 merged)

| State | Child | Latest |
|---|---|---|
| merged | <owner>/repo-a#101 | <PR URL> |
| merged | <owner>/repo-a#102 | <PR URL> |
| in-flight | <owner>/repo-b#103 | pr-open, <PR URL> |
| ready | <owner>/repo-b#104 | → firing worker this wake |
| waiting | <owner>/repo-c#105 | blocked by <owner>/repo-b#104 |
| blocked-user | <owner>/repo-c#106 | awaiting-manual-verification |
```

Post it by piping the body on stdin (no `Write` tool needed, stays inside the existing `gh issue comment` grant):

```
gh issue comment <parent-n> --repo <owner>/<repo> --body-file - <<'EOF'
<!-- ship-epic:status -->
... snapshot table ...
EOF
```

### Terminal block (Phase 8-style output)

```
/abc:ship-epic-gh wake <ts>
Parent: <owner>/<repo>#100  "Add WidgetRow to dashboard"  (4 of 6 merged)

[merged]         <owner>/repo-a#101  <PR URL>
[merged]         <owner>/repo-a#102  <PR URL>
[in-flight]      <owner>/repo-b#103  pr-open <PR URL>
[ready→firing]   <owner>/repo-b#104
[waiting]        <owner>/repo-c#105  blocked by <owner>/repo-b#104
[blocked-user]   <owner>/repo-c#106  awaiting-manual-verification

Next wake: /loop 10m /abc:ship-epic-gh <owner>/<repo>#100
```

Keep terminal output short on no-op wakes (no state changes since last wake): just one line — `no-op wake — 4 of 6 merged, 1 in-flight, 1 blocked-user`.

### Compact-on-merge (end of wake)

When this wake observed **one or more children newly reach `merged`** — derived statelessly by comparing against the most recent *prior* `<!-- ship-epic:status -->` comment (a child is newly merged when a prior status comment **exists** and didn't list it as `merged`) — print, after the terminal block, as the last output of the wake:

```
🗜 <n> child(ren) merged this wake. Run /compact now to free context before the next coordinator wake.
```

**First-wake baseline guard:** when no prior `<!-- ship-epic:status -->` comment exists — the first coordinator wake, including resuming an epic whose children already merged before the coordinator ever ran — treat the current `merged` set as the baseline, not as newly merged: this wake's status comment establishes the snapshot and no prompt is printed.

Skip in no-compact mode, on wakes with no newly-merged children, and on terminal wakes (all merged → the epic is closing and the loop is ending anyway). At most once per wake regardless of how many children merged. Full rules: [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

## Phase 5: Terminal states

### All children `merged`

1. Close the parent: `gh issue close <n> --repo <owner>/<repo> --reason completed`.
2. Write a completion comment: `<!-- ship-epic:event:complete --> ✅ Epic complete: <N> children merged.`
3. `CronDelete` the epic's `/loop` via the cron-entry match rule.
4. Worker loops should already have self-cancelled per `/abc:ship-issue-gh` Phase 7 — if any remain in `CronList`, leave them; they'll wake, derive `merged`, and self-cancel.

### Any child `failed`

A child counts as `failed` for the all-stop **only** when it carries the worker's `<!-- ship-issue:event:failed -->` marker. A child that is closed `not_planned` **without** that marker is a human cancellation, not a worker failure — classify it `dropped (human-canceled)` (Phase 2), surface it, and **do not halt**.

1. Write `<!-- ship-epic:event:failed -->` on the parent: `❌ Epic halted: <owner>/<repo>#<n> failed (<reason>). Other children left in their current state.`
2. `CronDelete` the epic's `/loop`.
3. **Also `CronDelete` all in-flight worker `/loop`s for this epic's children.** Identify each worker cron via the **Worker cron-match rule** (Phase 0.5) per child ID — not a loose substring. The epic is halted; workers shouldn't keep grinding. After killing a child's worker cron, append an **informational** comment to that child that does **NOT** contain any `<!-- ship-issue:* -->` marker (so it isn't mistaken for a worker-authored event): `Epic halted upstream; this child's worker loop was cancelled. Re-run `<worker-command> <owner>/<repo>#<n>` to resume.` (use the derived `<worker-command>`).
4. Leave the parent issue **open** — failure means a human needs to decide whether to close, redirect, or retry. Do not auto-close the parent on `failed`.
5. Halt.

### Dependency cycle (terminal)

Reached from Phase 1 when DFS detects a cycle:

1. Write `<!-- ship-epic:event:cycle -->` on the parent listing the cycle members in order — **once**: if an identical `<!-- ship-epic:event:cycle -->` marker comment already exists (same cycle membership), do **not** repost (dedup against the prior marker).
2. `CronDelete` the epic's `/loop`.
3. Halt. No workers were fired (Phase 1 refuses to proceed on a cycle).

### Parent unreadable (terminal)

Reached from Phase 2's read-failure rule when the **parent** is unreadable on **consecutive** wakes:

1. `CronDelete` the epic's `/loop`.
2. Halt — print the read error. The parent is the aggregation target; with it unreadable the coordinator can't classify anything. A single transient read failure does **not** trigger this — only consecutive-wake failure.

### Any child `blocked-user` or `external-blocker`

**Do not halt.** Leave the epic loop running — other workers may still be making progress. Surface in the terminal block and status comment, but the loop continues.

### User @-mentions Claude on the parent

Treat as a direct interrupt — read the comment via `gh api /repos/<owner>/<repo>/issues/<n>/comments`, decide whether to halt or adjust. If unclear, write a `blocked-user` comment with reason `user-mention-ambiguous:<comment-id>`, **`CronDelete` the epic's `/loop`** (this halt self-cancels like every other terminal path), and halt.

## Phase 6: Stop

The epic's `/loop` self-cancels on every terminal-state phase via `CronDelete`. The user should not have to run `/loop cancel` manually.

If `CronDelete` fails (entry already gone, job-ID not found), print a note and continue. The GitHub comment is authoritative.

## Notes on edge cases

- **Child added to the parent's task-list mid-flight**: next wake re-fetches the parent body. New entries with `repo:` labels become `ready` (if no `blocked-by:*`) or `waiting` (if blocked). Fired automatically.
- **Child removed from the task-list mid-flight**: if it's `in-flight`, leave its worker running — the worker is on its own contract. Just drop it from the epic's status aggregation.
- **`blocked-by:*` label added mid-flight to an `in-flight` child**: the worker keeps running. The label takes effect for state classification only — future ready/waiting decisions honor it; the current worker is not interrupted.
- **Multiple `/abc:ship-epic-gh` invocations on the same parent**: cron-match deduplicates (idempotent self-arm). Second invocation in the **same** session no-ops. A second invocation in a **different** session is caught by the Phase 0.5 § Single-session constraint first-wake checks (`possible-duplicate-coordinator` if a foreign `<!-- ship-epic:status -->` comment exists; `parent-already-serial-walked` if a `ship-issue-gh <PARENT-ID>` walker cron is live) — the coordinator is single-session per parent.
- **Worker death** (machine reboot, manual `/loop cancel`): next wake sees the worker as no longer `in-flight` but the child issue isn't terminal — re-classifies as `ready` (if blocks satisfied) and fires a new worker. Re-arming is idempotent at the worker level.
- **Cross-repo children with mismatched hosts** (github.com + Enterprise): Phase 0 halts if the parent is on one host and any child ref points to a different host. v1 single-host only.
- **Parent body manually edited mid-flight** (user re-orders the task-list, adds prose between entries): the skill respects whatever is between the fence markers on the next read. If the user accidentally deletes the markers, halt with `blocked-user` and reason `parent-task-list-fence-missing` — don't try to re-inject silently.
