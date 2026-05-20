# /ship-epic — Parallel Multi-Repo Feature Shipping

> Sketch / design doc. Not a committed skill yet. Decisions in this doc are recommendations, not locked.

## Purpose

Coordinator for a Linear **parent issue** whose sub-issues span multiple repos. Spawns one `/ship-issue` loop per ready sub-issue, gates blocked sub-issues until their dependencies merge, and aggregates status into the parent.

The motivation is the user-facing scenario from the insights report: today, a cross-repo epic with N sub-issues runs serially because `/ship-issue` walks its list one ticket at a time, even when sub-issues have no inter-dependencies. `/ship-epic` makes the genuinely-parallel parts actually parallel.

## Relationship to /ship-issue

- `/ship-issue` is the **worker**. Each ready sub-issue runs in its own `/loop 6m /ship-issue <SUB-ID>` — independent cron entry, independent state machine, independent Linear comments. Unchanged.
- `/ship-epic` is the **coordinator**. It doesn't implement code or open PRs directly; it manages which workers run, when, and aggregates their status into the parent.
- Workers don't know they're part of an epic. They report state to Linear (status, PR URLs, `<!-- ship-issue:* -->` comments) just like single-ticket runs. The coordinator reads that same state.

The design deliberately preserves `/ship-issue`'s existing contract — no flags, no parallel mode, no state-machine changes. The coordinator composes it.

## Inputs

- `PARENT-ID` — Linear parent issue with sub-issues (e.g. `PROJ-100`)
- Linear URL pointing at a parent — same normalization as `/ship-issue` Phase 0
- `milestone:<uuid>` — same semantics as `/ship-issue`; expands to non-terminal issues in the milestone

Single-ticket input (no sub-issues) → reject with a one-line note pointing the user at `/ship-issue` instead.

## Worker model: decision

**Independent `/ship-issue` loops, not Agent-tool subagents.**

Tradeoffs considered:

| Approach | Pros | Cons |
|---|---|---|
| **Subagents via Agent tool** | Parallel within one session; immediate visibility in main convo | Dies on session close; main context bloats; no cross-session resume; doesn't reuse `/ship-issue`'s battle-tested state machine |
| **Independent `/ship-issue` loops** (recommended) | Survives session close; reuses `/ship-issue` as-is; Linear-as-source-of-truth pattern composes naturally; truly parallel via independent cron entries | Visibility is via Linear status + terminal aggregation, not live agent output |

`/ship-issue`'s "stateless, Linear is the source of truth, survives session close" property dominates. `/ship-epic` inherits it.

## Dependency graph

Built from Linear issue relations on each sub-issue:

- `blocks` / `blocked by` — **strict ordering**: blocker must reach `merged` before the blocked sub-issue's worker fires
- `relates to` — informational, ignored
- Each sub-issue's `repo:<name>` label resolves to a workdir using `/ship-issue` Phase 1's rules unchanged

**Cycle detection**: if `blocks`/`blocked by` form a cycle → `blocked-user` on the parent with a one-line cycle description. Refuse to start until the human resolves it. Don't try to be clever.

## Coordinator workflow

### Phase 0: Parse, validate, self-arm

1. Resolve parent → sub-issue list (mirror `/ship-issue` Phase 0; for `milestone:` args, same expansion).
2. If only one sub-issue resolves → reject with "use `/ship-issue` for single tickets."
3. Self-arm `/loop 10m /ship-epic <raw-arg>` if no matching cron entry exists. Reuse `/ship-issue`'s cron-entry match rule (substring + word boundary) so re-invocations are idempotent.

### Phase 1: Build dependency graph

For each sub-issue:
- Fetch via `mcp__claude_ai_Linear__get_issue` with `includeRelations: true`
- Record `blocks`, `blocked by` edges (only edges where both endpoints are in our sub-issue set — external blockers are surfaced as `blocked-user`, not encoded in the graph)
- Resolve `repo:` label → workdir (Phase 1 of `/ship-issue`)
- Detect platform (github / gitlab) from the workdir's remote

Detect cycles → `blocked-user` on parent. Halt.

### Phase 2: Classify each sub-issue

State derivation (first match wins):

| State | Condition |
|---|---|
| `merged` | Linear status = Done AND a linked PR is merged |
| `failed` | A `<!-- ship-issue:event:failed -->` comment exists on the sub-issue |
| `blocked-user` | A `<!-- ship-issue:event:blocked -->` comment exists with no subsequent `event:resumed` |
| `in-flight` | A `CronList` entry matches `/ship-issue <SUB-ID>` (already running) |
| `ready` | All `blocked by` upstreams in `merged`, AND no in-flight cron, AND Linear status not terminal |
| `waiting` | One or more `blocked by` upstreams not yet `merged` |

Coordinator state is **derived fresh each wake** from Linear + `CronList`. Nothing is persisted locally. Same contract as `/ship-issue`.

### Phase 3: Fire workers

For each sub-issue in `ready`: invoke `Skill(skill: "loop", args: "6m /ship-issue <SUB-ID>")`. This kicks off the worker's first wake and arms its own loop. The coordinator does not wait — it returns and the worker runs independently.

Do not fire workers for `in-flight` sub-issues (the cron match prevents duplicates anyway; skip explicitly).

### Phase 4: Aggregate status

Append a `<!-- ship-epic:status -->` comment on the **parent** with a per-sub-issue summary. Append-only, matching `/ship-issue`'s comment audit-trail pattern.

Print a terminal block at the epic level:

```
/ship-epic wake <ts>
Parent: PROJ-100  (3 of 5 merged)

[merged]    PROJ-101  <PR URL>
[merged]    PROJ-102  <PR URL>
[in-flight] PROJ-103  pr-open  <PR URL>
[ready]     PROJ-104  → firing /loop 6m /ship-issue PROJ-104
[waiting]   PROJ-105  blocked by PROJ-104

Next wake: /loop 10m /ship-epic PROJ-100
```

### Phase 5: Terminal states

- **All sub-issues `merged`** → transition parent to Done, `CronDelete` the epic's loop, halt. Worker loops should already have self-cancelled per `/ship-issue` Phase 7.
- **Any sub-issue `failed`** → halt the epic, `CronDelete` the epic's loop AND all in-flight worker loops, write `<!-- ship-epic:event:failed -->` on the parent. **Open question**: should we let the rest finish? v1: halt — a cross-repo failure usually means the design has a problem worth pausing for. Easy to flip if it's wrong.
- **Any sub-issue `blocked-user`** → leave the epic loop running. Other workers can keep making progress; the blocked one waits for the human. Surface in the terminal block but don't halt the epic.

## Open questions (deliberately not resolved in v1)

1. **Soft merge gates** ("Sub-B can implement but not merge until Sub-A merges"). Would require a new state in `/ship-issue`. v1 only supports hard gates via `blocks`.
2. **Cross-repo package publishes** between sub-issues (Sub-A adds a type in `@company/foo`, Sub-B in another repo consumes it after publish). Out of scope — falls under org Pre-Task Check 1 ("upstream change must happen first"). Coordinator can surface this as a `blocked-user` if it sees a `repo:` dependency that requires a publish step, but the publish itself is manual in v1.
3. **Coordinator wake cadence**: 10 min vs 6 (matching workers). 10 is recommended — the coordinator only matters on a worker `merged` (unblocks downstream) or `failed`/`blocked-user` (epic-level decision). Both events show in Linear within seconds; 10-minute lag is acceptable and keeps cron noise down.
4. **Multiple coordinators on the same parent**: cron-match key is `/ship-epic <raw-arg>`. Second invocation no-ops, same as `/ship-issue`.
5. **Worker death detection**: if a worker's cron silently dies (machine reboot, manual `/loop cancel`), the coordinator will see it as no longer `in-flight` but Linear status hasn't reached terminal — should it re-arm? v1: yes, if the sub-issue is otherwise `ready`-eligible. Re-arming is idempotent at the worker level.

## What this doesn't do

- Doesn't implement code itself
- Doesn't open or merge PRs itself
- Doesn't run tests itself
- Doesn't replace `/ship-issue` — it composes it

## File layout (when implemented)

```
~/.claude/skills/ship-epic/
  SKILL.md      # operational procedure (mirrors /ship-issue style)
  DESIGN.md     # this doc, promoted from Desktop
  README.md     # user-facing usage examples
```

## Estimated complexity

- SKILL.md: probably ~250 lines (smaller than `/ship-issue` because the worker logic is delegated)
- No new MCP tools needed beyond what `/ship-issue` already uses
- Test surface: dependency-graph cycle detection, ready/waiting classification under various blocked-by topologies, idempotent self-arming
