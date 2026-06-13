---
name: ship-epic
description: Linear · Coordinator for a Linear parent issue whose sub-issues span multiple repos. Builds a dependency graph from sub-issue `blocks`/`blocked by` relations, fires `/loop /abc:ship-issue <SUB-ID>` per ready sub-issue (truly parallel via independent cron entries), gates blocked sub-issues until upstreams merge, aggregates status into the parent. Self-arms its own `/loop` — invoke once and walk away. TRIGGER when the user says "/ship-epic PARENT-ID", asks to "ship this epic", or wants to drive a Linear parent through merge in parallel across repos.
argument-hint: "PARENT-ID | https://linear.app/.../PARENT-ID [--no-compact]"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Read
  - mcp__claude_ai_Linear__get_issue
  - mcp__claude_ai_Linear__list_issues
  - mcp__claude_ai_Linear__save_issue
  - mcp__claude_ai_Linear__list_comments
  - mcp__claude_ai_Linear__save_comment
  - mcp__claude_ai_Linear__list_milestones
---

# /abc:ship-epic — Parallel multi-repo shipping coordinator

Drive a Linear **parent issue** with sub-issues to all-merged by firing one `/loop 6m /abc:ship-issue <SUB-ID>` per **ready** sub-issue, gating sub-issues with unmet `blocked by` relations, and aggregating status on the parent. Each worker (`/abc:ship-issue`) is independent — they run in parallel via their own cron entries, survive session close, and use Linear as the single source of truth.

This skill is the **coordinator**. It does NOT implement code, open PRs/MRs, or run tests directly — those are the workers' jobs.

See [`DESIGN.md`](./DESIGN.md) for the architectural design rationale. This file is the operational procedure.

## Hard rules

- **Never** spawn a worker for a sub-issue that has an unmet `blocked by` relation. Wait for the upstream to reach `merged` first.
- **Never** halt the epic just because one worker hits `blocked-user`. Other workers can continue; the blocked one waits for the human.
- **Never** modify worker state directly (no edits to `<!-- ship-issue:* -->` comments). Workers own their own state machines.
- **Always** self-cancel the epic's cron on terminal states (all merged, any failed). `/abc:ship-issue` self-cancels its own cron per its Phase 7; this skill mirrors that contract at the epic level.
- If the parent has no sub-issues → reject and point the user at `/abc:ship-issue` for single tickets.
- If the dependency graph has a cycle → **Phase 5 § Dependency cycle (terminal)**: write `<!-- ship-epic:event:cycle -->` once (dedup against an identical prior marker), `CronDelete` the epic's own loop, and halt. Refuse to fire any workers.

## Phase 0: Parse input and self-arm

### Normalize the arg

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-on-merge prompt (Phase 4) is skipped, and the flag propagates to every worker fired in Phase 3. The flag stays in the **raw arg string** used for cron arming/matching, so the opt-out survives every subsequent wake. Contract and rationale live in [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

`$ARGUMENTS` is one of:

1. **Linear issue URL** (`https://linear.app/<org>/issue/<id>`) → strip prefix, extract `TEAM-N` (the parent ID).
2. **Linear project URL** (`https://linear.app/<org>/project/<slug>/...`) — project overview / issues / triage URLs that don't point at a parent issue → `blocked-user` with reason `project-url-needs-parent-id`. The block message lists the two supported shapes: bare parent ID (`PROJ-100`) and parent issue URL. Do not proceed to Phase 0.5 — no cron arming.
3. **Bare ID** (e.g. `PROJ-100`) → use as-is.
4. **`milestone:<uuid>` (or a project URL with a `#milestone-<uuid>` fragment)** → **reject.** The coordinator pattern needs a real parent issue for status aggregation — point the user at `/abc:ship-issue milestone:<uuid>` (the serial walker) instead. This mirrors how `/abc:ship-epic-gh` rejects milestone refs. `blocked-user` with reason `milestone-needs-serial-walker`; do not proceed to Phase 0.5 — no cron arming. (Whether a milestone-mode coordinator is worth building is an open question — see [`DESIGN.md`](./DESIGN.md) § Open questions.)

For the rest of this doc, assume **bare PARENT-ID** unless noted.

### Fetch parent + sub-issues

1. `mcp__claude_ai_Linear__get_issue` with `id: PARENT-ID`, `includeRelations: true`. Read description, labels, `statusType`.
2. **Already-complete early exit.** If the parent's `statusType` is `completed` (Done) on a fresh invocation → the epic is already complete. Print a one-line "epic already complete" summary and exit **without arming a loop and without writing any comment** (mirrors the `/abc:ship-epic-gh` closed-completed early exit). Do not proceed to Phase 0.5.
3. `mcp__claude_ai_Linear__list_issues` with `parentId: PARENT-ID`, no status filter (we want everything, including merged ones to derive `merged` state).

If the sub-issue list is empty → reject: "PARENT-ID has no sub-issues. Use `/abc:ship-issue PARENT-ID` for single-ticket shipping."

### Self-arm the loop

Mirror `/abc:ship-issue` Phase 0.5's cron-entry match rule:

#### Cron-entry match rule

> A `CronList` entry **matches** this invocation when its command string contains `<command-name> <raw-arg>` **followed by a word boundary** — the next character (if any) must NOT be alphanumeric, `-`, or `,`. `<command-name>` is the literal slash-command name Claude Code injects for this invocation (e.g. `/ship-epic` when invoked top-level, or `/<plugin>:ship-epic` when invoked through a plugin namespace — verify from the `<command-name>` tag Claude Code passes at invocation time, including on `/loop`-triggered wakes where the inner command name is still surfaced).
>
> Reading the **actually-injected** name — rather than hardcoding `/ship-epic` — is load-bearing for plugin-namespaced invocations: the hardcoded substring `/ship-epic` is **not** present in `/abc:ship-epic <raw-arg>` (the prefix is `/abc:`, not `/`), so the match always failed and every wake duplicate-armed a new cron.
>
> **Fallback regex** when `<command-name>` isn't reachable (older Claude Code versions, edge cases): test the entry's command string against `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-epic <raw-arg>(?![A-Za-z0-9_,-])`. The optional `<plugin>:` prefix capture covers any plugin-namespacing scheme; the trailing negative-lookahead is the same boundary class as the strict rule.
>
> Boundary check works whether `CronList` reports the wrapped form `/loop 10m <command-name> <raw-arg>` or the inner `<command-name> <raw-arg>`.

#### Arm check

- If a matching entry exists → no-op, proceed to Phase 1 (the common path on loop-triggered wakes).
- If no match → this is the **first wake**. Run the **single-session constraint** checks below before arming. If they pass, invoke `Skill(skill: "loop", args: "10m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1 — the first wake also does the work of the first iteration.

#### Single-session constraint (first wake only)

The coordinator is single-session: exactly one coordinator loop per parent. On the **first wake** (no matching cron yet — about to arm), before arming:

- **Live sibling coordinator.** If a recent `<!-- ship-epic:status -->` comment exists on the parent that **THIS session did not write**, suspect a live sibling coordinator already running in another session → `blocked-user` with reason `possible-duplicate-coordinator`. Do not arm a second loop.
- **Parent already serial-walked.** If `CronList` shows a **serial-walker** entry for this same parent — a worker cron of the form `ship-issue <PARENT-ID>` (the namespace-aware worker cron-match rule below applied to the *parent's* own ID, i.e. someone ran `/abc:ship-issue <parent>` to walk the sub-issues serially) → refuse to start with reason `parent-already-serial-walked`. Coordinating in parallel while the parent is being walked serially would double-fire workers.

(On non-first wakes a matching coordinator cron exists, so these checks are skipped — they guard the initial arm only.)

10-minute cadence is intentional (longer than the 6-minute worker cadence): the coordinator only needs to react when a worker reaches `merged` (unblocks downstream) or terminal (`failed`/`blocked-user`). Both events surface in Linear within seconds; 10-minute lag is acceptable.

### Derived worker command (defined once — referenced by Phase 2 in-flight match AND Phase 3 fire string)

**Do not hardcode `/abc:`.** Derive the worker command from the **captured coordinator `<command-name>`** so a coordinator invoked top-level fires a top-level worker, and a plugin-namespaced coordinator fires a same-namespace worker:

> `<worker-command>` = the captured `<command-name>` with its trailing skill name `ship-epic` swapped to `ship-issue`, preserving any namespace prefix verbatim. So `/abc:ship-epic` → `/abc:ship-issue`, and a top-level `/ship-epic` → `/ship-issue`.

#### Worker cron-match rule (the single match key)

The Phase 3 fire string and the Phase 2 `in-flight` match key **MUST be the same string** — they are defined here once and referenced from both. Firing `/loop 6m <worker-command> <SUB-ID>` while classifying `in-flight` against a *different* substring (e.g. the hardcoded `/ship-issue <SUB-ID>`) is exactly the bug this fixes: the namespaced fire string `/abc:ship-issue <SUB-ID>` never matches a bare `/ship-issue <SUB-ID>` grep, so the coordinator never recognizes its own running workers and re-fires duplicates.

> A `CronList` entry is the **worker for sub-issue `<SUB-ID>`** when its command string matches the **namespace-aware regex** (same shape as the epic's own cron-match rule, with the Linear-ID boundary class):
>
> `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue <SUB-ID>(?![A-Za-z0-9_,-])`
>
> The optional `<plugin>:` prefix capture matches whatever namespace the worker was fired under (it is the same namespace as `<worker-command>`); the trailing negative-lookahead is the Linear-ID boundary class (no `/`/`#` exclusions — the GitHub sibling needs those, Linear doesn't). This is the **same string** as the Phase 3 fire string's command portion — define it once here, reference it by name from both Phase 2 (`in-flight`) and Phase 5 (kill targeting).

## Phase 1: Build the dependency graph

For each sub-issue:

1. Read its `blocks` and `blocked by` relations from the `relations` field on the `get_issue` response.
2. Filter relations: only keep edges where BOTH endpoints are in our sub-issue set. External blockers (e.g. a sub-issue blocked by a ticket outside this epic) surface as the `external-blocker` state for that sub-issue (Phase 2), recorded only in the epic's `<!-- ship-epic:status -->` comment — never as a comment on the sub-issue itself.
3. Build adjacency lists: `blocksMap[id]: Set<id>`, `blockedByMap[id]: Set<id>`.

Detect cycles via DFS. On cycle → go to **Phase 5 § Dependency cycle (terminal)** — refuse to fire any workers. Phase 5 owns the marker-dedup + `CronDelete` + halt; do not write the marker or fire workers here.

## Phase 2: Classify each sub-issue

First match wins (no need to re-read CronList per sub-issue — pull it once at the top of the phase):

| State | Condition |
|---|---|
| `merged` | Linear `statusType` is `completed` AND a `<!-- ship-issue:event:merged -->` comment exists (worker reached its merged terminal) — OR `statusType` is `completed` with **no** `event:merged` marker and **no** linked PR/MR (a human marked it Done directly — treat as done) |
| `failed` | A `<!-- ship-issue:event:failed -->` comment from the worker exists |
| `blocked-user` | The sub-issue's latest `<!-- ship-issue:event:blocked -->` marker is **not postdated** by a human (non-skill) comment or a `<!-- ship-issue:verify:passed -->` marker. (See **Re-fire on human reply** below: if a human reply / verify marker *does* postdate the blocked marker, the sub-issue is **re-fireable**, not still-blocked — it classifies `ready` when blockers are satisfied.) |
| `external-blocker` | A `blocked by` relation points to an issue outside our sub-issue set AND that issue is not merged. Recorded only in the epic's `<!-- ship-epic:status -->` comment — never written as a comment on the sub-issue |
| `in-flight` | A `CronList` entry matches the **worker cron-match rule** for this sub-issue (Phase 0.5 § Worker cron-match rule — the same `(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue <SUB-ID>` namespace-aware key the Phase 3 fire string uses) |
| `dropped (human-canceled)` | Linear `statusType` is `canceled` BUT **no** `<!-- ship-issue:event:failed -->` marker (a human canceled the issue directly — not a worker failure). Surface in the status comment as `dropped (human-canceled)`; **do not** count toward the all-stop halt (Phase 5 § Any sub-issue failed). The epic continues |
| `ready` | All `blocked by` upstreams in `merged`, AND no in-flight cron, AND Linear state not terminal. Includes a **re-fireable** previously-blocked sub-issue (see **Re-fire on human reply**) |
| `waiting` | One or more in-set `blocked by` upstreams not yet `merged` |
| `blocked-user: unclassifiable-child` | **Catch-all** — no row above matched. A sub-issue can never fall through the table silently; surface it as `blocked-user` with reason `unclassifiable-child` so a human looks at it |

**Re-fire on human reply (how a blocked sub-issue resumes).** No worker ever writes an `event:resumed` marker — there is no such marker. A `blocked-user` sub-issue resumes by the coordinator **re-firing its worker**. The rule: take the sub-issue's latest `<!-- ship-issue:event:blocked -->` marker. If a **human (non-skill) comment** or a `<!-- ship-issue:verify:passed -->` marker postdates it (later timestamp), the human has answered the block → treat the sub-issue as re-fireable: it classifies `ready` (if its blockers are satisfied and no worker cron is in-flight) and Phase 3 fires a fresh worker, which is what resumes it. If nothing postdates the blocked marker, the sub-issue is still `blocked-user` and waits.

**Read-failure rule.** Mirror the worker's rule (`/abc:ship-issue` Phase 3): if **any** read this phase fails (non-zero exit, timeout, an MCP error, pagination the coordinator can't reconcile), **skip classifying that sub-issue this wake** — do not fall through to a wrong state (e.g. treating an unread `list_comments` as "no blocked marker"). The sub-issue keeps its prior surfaced state until a clean read. If the **parent** itself is unreadable on **consecutive** wakes → `CronDelete` the epic's loop and halt (Phase 5 § Parent unreadable).

Re-derive fresh on every wake — nothing is persisted locally.

## Phase 3: Fire workers for ready sub-issues

For each sub-issue in `ready` state, fire the **derived `<worker-command>`** (Phase 0.5 § Derived worker command — never the hardcoded `/abc:` literal):

```
Skill(skill: "loop", args: "6m <worker-command> <SUB-ID>")
```

The `<worker-command> <SUB-ID>` portion is the **same string** the Phase 2 `in-flight` worker cron-match rule keys on — that is what lets the next wake recognize this worker as `in-flight` instead of re-firing it. (e.g. coordinator `/abc:ship-epic` → `<worker-command>` is `/abc:ship-issue`.)

In no-compact mode, append the flag so workers inherit the opt-out: `Skill(skill: "loop", args: "6m <worker-command> <SUB-ID> --no-compact")` (see `../_shared/compact-on-merge.md` § `--no-compact`).

This kicks off the worker's first wake and arms its own cron. The coordinator does NOT wait — it returns and the worker runs independently on its own loop.

**Do not fire** workers for sub-issues already `in-flight` (the worker's own Phase 0.5 cron-match would no-op anyway, but skip explicitly for clarity and to avoid any potential race).

If multiple sub-issues are `ready` in the same wake, fire all of them — the workers run in parallel on independent cron entries.

## Phase 4: Aggregate status

### Linear comment on the parent

Append (not edit) a single `<!-- ship-epic:status -->` comment on the parent with the current snapshot:

```
<!-- ship-epic:status -->
Wake: 2026-05-17T18:30:00Z  (4 of 6 merged)

| State | Sub-issue | Latest |
|---|---|---|
| merged | PROJ-101 | <PR URL> |
| merged | PROJ-102 | <PR URL> |
| in-flight | PROJ-103 | pr-open, <PR URL> |
| ready | PROJ-104 | → firing worker this wake |
| waiting | PROJ-105 | blocked by PROJ-104 |
| blocked-user | PROJ-106 | awaiting-manual-verification |
```

### Terminal block (Phase 8-style output)

```
/abc:ship-epic wake <ts>
Parent: PROJ-100  "Add WidgetRow to dashboard"  (4 of 6 merged)

[merged]         PROJ-101  <PR URL>
[merged]         PROJ-102  <PR URL>
[in-flight]      PROJ-103  pr-open <PR URL>
[ready→firing]   PROJ-104
[waiting]        PROJ-105  blocked by PROJ-104
[blocked-user]   PROJ-106  awaiting-manual-verification

Next wake: /loop 10m /abc:ship-epic PROJ-100
```

Keep terminal output short on no-op wakes (no state changes since last wake) — just one line: `no-op wake — 4 of 6 merged, 1 in-flight, 1 blocked-user`.

### Compact-on-merge (end of wake)

When this wake observed **one or more sub-issues newly reach `merged`** — derived statelessly by comparing against the most recent *prior* `<!-- ship-epic:status -->` comment (a child is newly merged when a prior status comment **exists** and didn't list it as `merged`) — print, after the terminal block, as the last output of the wake:

```
🗜 <n> child(ren) merged this wake. Run /compact now to free context before the next coordinator wake.
```

**First-wake baseline guard:** when no prior `<!-- ship-epic:status -->` comment exists — the first coordinator wake, including resuming an epic whose sub-issues already merged before the coordinator ever ran — treat the current `merged` set as the baseline, not as newly merged: this wake's status comment establishes the snapshot and no prompt is printed.

Skip in no-compact mode, on wakes with no newly-merged children, and on terminal wakes (all merged → the epic is closing and the loop is ending anyway). At most once per wake regardless of how many children merged. Full rules: [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

## Phase 5: Terminal states

### All sub-issues `merged`

1. Transition parent to `Done` via `save_issue`.
2. Write `<!-- ship-epic:event:complete -->` comment: `✅ Epic complete: <N> sub-issues merged.`
3. Cancel the epic's `/loop` via `CronDelete` (use the same match rule as Phase 0).
4. Worker loops should already have self-cancelled per `/abc:ship-issue` Phase 7 — if any remain in `CronList`, leave them; they'll wake, derive `merged`, and self-cancel.

### Any sub-issue `failed`

A sub-issue counts as `failed` for the all-stop **only** when it carries the worker's `<!-- ship-issue:event:failed -->` marker. A sub-issue that is `canceled` **without** that marker is a human cancellation, not a worker failure — classify it `dropped (human-canceled)` (Phase 2), surface it, and **do not halt**.

1. Write `<!-- ship-epic:event:failed -->` on the parent: `❌ Epic halted: <SUB-ID> failed (<reason>). Other sub-issues left in their current state.`
2. `CronDelete` the epic's `/loop`.
3. **Also `CronDelete` all in-flight worker `/loop`s** for this epic's sub-issues — they shouldn't keep grinding after the epic is halted. Identify each worker cron via the **Worker cron-match rule** (Phase 0.5) per sub-issue ID — not a loose substring. After killing a sub-issue's worker cron, append an **informational** comment to that sub-issue that does **NOT** contain any `<!-- ship-issue:* -->` marker (so it isn't mistaken for a worker-authored event): `Epic halted upstream; this sub-issue's worker loop was cancelled. Re-run `<worker-command> <SUB-ID>` to resume.` (use the derived `<worker-command>`).
4. Halt.

> **Open question**: should we let other workers finish even if one failed? v1 halts because cross-repo failures usually mean the design has a problem. If this is wrong in practice, flip to "let others continue, just block fan-out."

### Dependency cycle (terminal)

Reached from Phase 1 when DFS detects a cycle:

1. Write `<!-- ship-epic:event:cycle -->` on the parent listing the cycle members in order — **once**: if an identical `<!-- ship-epic:event:cycle -->` marker comment already exists (same cycle membership), do **not** repost (dedup against the prior marker).
2. `CronDelete` the epic's `/loop`.
3. Halt. No workers were fired (Phase 1 refuses to proceed on a cycle).

### Parent unreadable (terminal)

Reached from Phase 2's read-failure rule when the **parent** is unreadable on **consecutive** wakes:

1. `CronDelete` the epic's `/loop`.
2. Halt — print the read error. The parent is the aggregation target; with it unreadable the coordinator can't classify anything. A single transient read failure does **not** trigger this — only consecutive-wake failure.

### Any sub-issue `blocked-user` or `external-blocker`

**Do not halt.** Leave the epic loop running — other workers may still be making progress. Surface in the terminal block and Linear status comment, but the loop continues.

### User @-mentions Claude on the parent

Treat as a direct interrupt — read the comment, decide whether to halt or adjust. If unclear, write a `blocked-user` comment with reason `user-mention-ambiguous:<parent-comment-id>`, **`CronDelete` the epic's `/loop`** (this halt self-cancels like every other terminal path), and halt.

## Phase 6: Stop

The epic's `/loop` self-cancels on every terminal-state phase via `CronDelete`. The user should not have to run `/loop cancel` manually.

If `CronDelete` fails (entry already gone, job-ID not found), print a note and continue. The Linear comment is authoritative.

## Notes on edge cases

- **Sub-issue added to the parent mid-flight**: next wake re-fetches the sub-issue list. New sub-issues with `repo:` labels become `ready` (if no `blocked by`) or `waiting` (if blocked). Fired automatically.
- **Sub-issue removed from the parent mid-flight**: if it's `in-flight`, leave its worker running — the worker is on its own contract. Just drop it from the epic's status aggregation.
- **`blocked by` edge added mid-flight to an `in-flight` sub-issue**: the worker keeps running. The edge takes effect for state classification only — if the worker reaches a terminal state and a new sub-issue depends on it, the dependency is honored from then on.
- **Multiple `/abc:ship-epic` invocations on the same parent**: cron-match deduplicates (idempotent self-arm). Second invocation in the **same** session no-ops. A second invocation in a **different** session is caught by the Phase 0.5 § Single-session constraint first-wake checks (`possible-duplicate-coordinator` if a foreign `<!-- ship-epic:status -->` comment exists; `parent-already-serial-walked` if a `ship-issue <PARENT-ID>` walker cron is live) — the coordinator is single-session per parent.
- **Worker death** (machine reboot, manual `/loop cancel`): next wake sees the worker as no longer `in-flight` but Linear state not terminal — re-classifies as `ready` (if blocks satisfied) and fires a new worker. Re-arming is idempotent at the worker level.
