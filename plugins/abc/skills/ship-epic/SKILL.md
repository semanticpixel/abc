---
name: ship-epic
description: Linear · Coordinator for a Linear parent issue whose sub-issues span multiple repos. Builds a dependency graph from sub-issue `blocks`/`blocked by` relations, fires `/loop /abc:ship-issue <SUB-ID>` per ready sub-issue (truly parallel via independent cron entries), gates blocked sub-issues until upstreams merge, aggregates status into the parent. Self-arms its own `/loop` — invoke once and walk away. TRIGGER when the user says "/ship-epic PARENT-ID", asks to "ship this epic", or wants to drive a Linear parent through merge in parallel across repos.
argument-hint: "PARENT-ID | https://linear.app/.../PARENT-ID | milestone:<uuid>"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Read
  - AskUserQuestion
  - Bash(pwd:*)
  - Bash(ls:*)
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
- If the dependency graph has a cycle → halt with `blocked-user` and a one-line cycle description. Refuse to start.

## Phase 0: Parse input and self-arm

### Normalize the arg

`$ARGUMENTS` is one of:

1. **Linear URL** → strip prefix, extract `TEAM-N`.
2. **Bare ID** (e.g. `PROJ-100`) → use as-is.
3. **`milestone:<uuid>`** → expand via the same logic as `/abc:ship-issue` Phase 0 milestone expansion: resolve to project, list non-terminal issues, filter by milestone, order by `createdAt`. For `/abc:ship-epic`, the resulting list IS the sub-issue set (no parent created). The "parent" for status aggregation is the milestone itself — write `<!-- ship-epic:* -->` comments on each milestone issue's project rather than a parent issue. (Open question: is this useful? v1 supports the case but the cleanest input is a real parent ID.)

For the rest of this doc, assume **bare PARENT-ID** unless noted.

### Fetch parent + sub-issues

1. `mcp__claude_ai_Linear__get_issue` with `id: PARENT-ID`, `includeRelations: true`. Read description, labels.
2. `mcp__claude_ai_Linear__list_issues` with `parentId: PARENT-ID`, no status filter (we want everything, including merged ones to derive `merged` state).

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
- If no match → invoke `Skill(skill: "loop", args: "10m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1 — the first wake also does the work of the first iteration.

10-minute cadence is intentional (longer than the 6-minute worker cadence): the coordinator only needs to react when a worker reaches `merged` (unblocks downstream) or terminal (`failed`/`blocked-user`). Both events surface in Linear within seconds; 10-minute lag is acceptable.

## Phase 1: Build the dependency graph

For each sub-issue:

1. Read its `blocks` and `blocked by` relations from the `relations` field on the `get_issue` response.
2. Filter relations: only keep edges where BOTH endpoints are in our sub-issue set. External blockers (e.g. a sub-issue blocked by a ticket outside this epic) surface as `blocked-user` for that sub-issue with reason `external-blocker:<ID>`.
3. Build adjacency lists: `blocksMap[id]: Set<id>`, `blockedByMap[id]: Set<id>`.

Detect cycles via DFS. On cycle → write `<!-- ship-epic:event:cycle -->` comment on the parent listing the cycle, transition the epic to halt (Phase 5), refuse to fire any workers.

## Phase 2: Classify each sub-issue

First match wins (no need to re-read CronList per sub-issue — pull it once at the top of the phase):

| State | Condition |
|---|---|
| `merged` | Linear `state.type` is `completed` AND a `<!-- ship-issue:event:merged -->` comment exists (worker reached its merged terminal) — OR the Linear state is Done and any linked PR/MR is merged |
| `failed` | A `<!-- ship-issue:event:failed -->` comment exists OR Linear state is Canceled |
| `blocked-user` | A `<!-- ship-issue:event:blocked -->` exists with no subsequent `event:resumed` |
| `external-blocker` | A `blocked by` relation points to an issue outside our sub-issue set AND that issue is not merged |
| `in-flight` | A `CronList` entry matches `/abc:ship-issue <SUB-ID>` (worker is running) |
| `ready` | All `blocked by` upstreams in `merged`, AND no in-flight cron, AND Linear state not terminal |
| `waiting` | One or more in-set `blocked by` upstreams not yet `merged` |

Re-derive fresh on every wake — nothing is persisted locally.

## Phase 3: Fire workers for ready sub-issues

For each sub-issue in `ready` state:

```
Skill(skill: "loop", args: "6m /abc:ship-issue <SUB-ID>")
```

This kicks off the worker's first wake and arms its own cron. The coordinator does NOT wait — it returns and the worker runs independently on its own loop.

**Do not fire** workers for sub-issues already `in-flight` (the worker's own Phase 0.5 cron-match would no-op anyway, but skip explicitly for clarity and to avoid any potential race).

If multiple sub-issues are `ready` in the same wake, fire all of them — the workers run in parallel on independent cron entries.

## Phase 4: Aggregate status

### Linear comment on the parent

Append (not edit) a single `<!-- ship-epic:status -->` comment on the parent with the current snapshot:

```
<!-- ship-epic:status -->
Wake: 2026-05-17T18:30:00Z  (4 of 6 merged)

| ST | State | Sub-issue | Latest |
|---|---|---|---|
| ST-1 | merged | PROJ-101 | <PR URL> |
| ST-2 | merged | PROJ-102 | <PR URL> |
| ST-3 | in-flight | PROJ-103 | pr-open, <PR URL> |
| ST-4 | ready | PROJ-104 | → firing worker this wake |
| ST-5 | waiting | PROJ-105 | blocked by PROJ-104 |
| ST-6 | blocked-user | PROJ-106 | awaiting-manual-verification |
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

## Phase 5: Terminal states

### All sub-issues `merged`

1. Transition parent to `Done` via `save_issue`.
2. Write `<!-- ship-epic:event:complete -->` comment: `✅ Epic complete: <N> sub-issues merged.`
3. Cancel the epic's `/loop` via `CronDelete` (use the same match rule as Phase 0).
4. Worker loops should already have self-cancelled per `/abc:ship-issue` Phase 7 — if any remain in `CronList`, leave them; they'll wake, derive `merged`, and self-cancel.

### Any sub-issue `failed`

1. Write `<!-- ship-epic:event:failed -->` on the parent: `❌ Epic halted: <SUB-ID> failed (<reason>). Other sub-issues left in their current state.`
2. `CronDelete` the epic's `/loop`.
3. **Also `CronDelete` all in-flight worker `/loop`s** for this epic's sub-issues — they shouldn't keep grinding after the epic is halted. Identify them via `CronList` + sub-issue ID match.
4. Halt.

> **Open question**: should we let other workers finish even if one failed? v1 halts because cross-repo failures usually mean the design has a problem. If this is wrong in practice, flip to "let others continue, just block fan-out."

### Any sub-issue `blocked-user` or `external-blocker`

**Do not halt.** Leave the epic loop running — other workers may still be making progress. Surface in the terminal block and Linear status comment, but the loop continues.

### User @-mentions Claude on the parent

Treat as a direct interrupt — read the comment, decide whether to halt or adjust. If unclear, write a `blocked-user` comment with reason `user-mention-ambiguous:<parent-comment-id>` and halt.

## Phase 6: Stop

The epic's `/loop` self-cancels on every terminal-state phase via `CronDelete`. The user should not have to run `/loop cancel` manually.

If `CronDelete` fails (entry already gone, job-ID not found), print a note and continue. The Linear comment is authoritative.

## Notes on edge cases

- **Sub-issue added to the parent mid-flight**: next wake re-fetches the sub-issue list. New sub-issues with `repo:` labels become `ready` (if no `blocked by`) or `waiting` (if blocked). Fired automatically.
- **Sub-issue removed from the parent mid-flight**: if it's `in-flight`, leave its worker running — the worker is on its own contract. Just drop it from the epic's status aggregation.
- **`blocked by` edge added mid-flight to an `in-flight` sub-issue**: the worker keeps running. The edge takes effect for state classification only — if the worker reaches a terminal state and a new sub-issue depends on it, the dependency is honored from then on.
- **Multiple `/abc:ship-epic` invocations on the same parent**: cron-match deduplicates (idempotent self-arm). Second invocation no-ops.
- **Worker death** (machine reboot, manual `/loop cancel`): next wake sees the worker as no longer `in-flight` but Linear state not terminal — re-classifies as `ready` (if blocks satisfied) and fires a new worker. Re-arming is idempotent at the worker level.
