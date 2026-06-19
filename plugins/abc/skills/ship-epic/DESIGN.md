# /ship-epic — Parallel Multi-Repo Feature Shipping

> Design doc for the shipped `/abc:ship-epic` skill. Architectural rationale + locked decisions; the operational contract is [`SKILL.md`](./SKILL.md). When the two disagree, SKILL.md is authoritative — sync this doc to it.

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

**Not supported** (rejected at Phase 0, mirroring `/ship-epic-gh`):

- `milestone:<uuid>` (or a project URL with a `#milestone-<uuid>` fragment) — the coordinator pattern needs a real parent issue as the status-aggregation target. Rejected with reason `milestone-needs-serial-walker`, pointing the user at `/abc:ship-issue milestone:<uuid>` (the serial walker). See Open questions.
- Project URLs that don't point at a parent → `project-url-needs-parent-id`.

Single-ticket input (no sub-issues) → reject with a one-line note pointing the user at `/ship-issue` instead.
Parent already Done (`statusType=completed`) on a fresh invocation → print "epic already complete" and exit without arming a loop or writing a comment (mirrors `/ship-epic-gh`).

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

**Cycle detection**: if `blocks`/`blocked by` form a cycle → it's a **Phase 5 terminal**: write `<!-- ship-epic:event:cycle -->` on the parent **once** (dedup against an identical prior marker — don't repost a cycle that's already recorded), `CronDelete` the epic's own loop, and halt. Refuse to fire any workers. Don't try to be clever; the human resolves the cycle and re-runs.

## Coordinator workflow

### Phase 0: Parse, validate, self-arm

1. Resolve parent → sub-issue list (mirror `/ship-issue` Phase 0). `milestone:` and project URLs without a parent are **rejected**, not expanded — the coordinator needs a real parent.
2. If only one sub-issue resolves → reject with "use `/ship-issue` for single tickets." If the parent is already Done → print "epic already complete" and exit (no loop, no comment).
3. Self-arm `/loop 10m <command-name> <raw-arg>` if no matching cron entry exists — substituting the captured `<command-name>` (the slash-command name Claude Code injects, e.g. `/abc:ship-epic`) verbatim. Reuse `/ship-issue`'s cron-entry match rule (captured `<command-name>` + word boundary, permissive regex fallback) so re-invocations are idempotent.
4. **Single-session constraint (first wake only).** Before arming the very first loop: if a recent `<!-- ship-epic:status -->` comment exists that this session didn't write → `blocked-user: possible-duplicate-coordinator` (a sibling coordinator may be live in another session). If `CronList` shows a serial-walker `ship-issue <PARENT-ID>` cron for this same parent → refuse with `parent-already-serial-walked`. One coordinator loop per parent.
5. **Worker command + worker cron-match are derived from the captured `<command-name>`** (`ship-epic`→`ship-issue`, namespace preserved) and defined **once** — the Phase 3 fire string and the Phase 2 `in-flight` match key are the **same string** (the namespace-aware regex `(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue <SUB-ID>` with the Linear-ID boundary class). Never hardcode `/abc:`. This is the fix for the in-flight-never-matches-own-workers bug.

### Phase 1: Build dependency graph

For each sub-issue:
- Fetch via `mcp__claude_ai_Linear__get_issue` with `includeRelations: true`
- Record `blocks`, `blocked by` edges (only edges where both endpoints are in our sub-issue set — external blockers are surfaced as `blocked-user`, not encoded in the graph)
- Resolve `repo:` label → workdir (Phase 1 of `/ship-issue`)
- Detect platform (github / gitlab) from the workdir's remote

Detect cycles via DFS. On cycle → **Phase 5 § Dependency cycle (terminal)**: refuse to fire any workers; Phase 5 writes the deduped `<!-- ship-epic:event:cycle -->` marker, `CronDelete`s the loop, and halts. Do not write the marker or fire workers here.

### Phase 2: Classify each sub-issue

State derivation (first match wins) — kept in sync with SKILL.md Phase 2 (the authoritative copy):

| State | Condition |
|---|---|
| `merged` | `statusType=completed` AND a `<!-- ship-issue:event:merged -->` marker exists — OR `statusType=completed` with **no** `event:merged` marker and **no** linked PR/MR **and no `## Validation` heading** (human marked it Done directly; treat as done — a `## Validation`-gated issue is excluded from this arm so it falls through rather than skipping the verify gate) |
| `failed` | A `<!-- ship-issue:event:failed -->` marker from the worker exists |
| `blocked-user` | `statusType` is neither `completed` nor `canceled` (a blocked-then-canceled child falls through to `dropped (human-canceled)`), AND the latest `<!-- ship-issue:event:blocked -->` marker is **not postdated** by a human (non-skill) comment or a `<!-- ship-issue:verify:passed -->` marker. (There is **no** `event:resumed` marker — a blocked child resumes by the coordinator re-firing its worker once a human reply / verify marker postdates the blocked marker; see Re-fire on human reply.) |
| `external-blocker` | A `blocked by` relation points outside the sub-issue set AND that issue isn't merged. Recorded **only** in the epic's `<!-- ship-epic:status -->` comment — never as a comment on the sub-issue |
| `in-flight` | A `CronList` entry matches the worker cron-match rule for `<SUB-ID>` (the namespace-aware `(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue <SUB-ID>` key — same string as the Phase 3 fire string) |
| `dropped (human-canceled)` | `statusType=canceled` but **no** `event:failed` marker (human canceled directly — not a worker failure). Surface as `dropped (human-canceled)`; does **not** halt the epic |
| `ready` | All `blocked by` upstreams `merged`, no in-flight cron, status not terminal — including a re-fireable previously-blocked child |
| `waiting` | One or more in-set `blocked by` upstreams not yet `merged` |
| `blocked-user: unclassifiable-child` | Catch-all — no row matched. A child never falls through silently |

**Re-fire on human reply.** No `event:resumed` marker exists. A `blocked-user` child becomes re-fireable (classify `ready` if blockers satisfied) when a human comment or `verify:passed` marker postdates its latest `event:blocked` marker — re-firing the worker is how a blocked child resumes.

**Read-failure rule.** Any failed read (non-zero exit, timeout, MCP error, unreconcilable pagination) → skip classifying that child this wake (don't fall through to a wrong state). Parent unreadable on consecutive wakes → `CronDelete` + halt.

Coordinator state is **derived fresh each wake** from Linear + `CronList`. Nothing is persisted locally. Same contract as `/ship-issue`.

### Phase 3: Fire workers

For each sub-issue in `ready`: invoke `Skill(skill: "loop", args: "6m <worker-command> <SUB-ID>")` using the **derived `<worker-command>`** (Phase 0 step 5 — never a hardcoded `/abc:` literal). The `<worker-command> <SUB-ID>` portion is the same string the Phase 2 `in-flight` match keys on. This kicks off the worker's first wake and arms its own loop. The coordinator does not wait — it returns and the worker runs independently.

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
[ready]     PROJ-104  → firing /loop 6m <worker-command> PROJ-104
[waiting]   PROJ-105  blocked by PROJ-104

Next wake: /loop 10m /ship-epic PROJ-100
```

### Phase 5: Terminal states

- **All sub-issues `merged`** → transition parent to Done, `CronDelete` the epic's loop, halt. Worker loops should already have self-cancelled per `/ship-issue` Phase 7.
- **Any sub-issue `failed`** (worker `event:failed` marker present) → halt the epic, `CronDelete` the epic's loop AND every in-flight worker loop (identified via the worker cron-match rule per sub-issue ID), and append a **non-marker** informational comment to each killed child ("Epic halted upstream; … re-run `<worker-command> <SUB-ID>` to resume") so it isn't mistaken for a worker event. Write `<!-- ship-epic:event:failed -->` on the parent. **A child closed/canceled WITHOUT the worker's `event:failed` marker is a human cancellation → `dropped (human-canceled)`, surfaced and continued, NOT a halt.** **Open question**: should we let the rest finish even on a real failure? v1: halt — a cross-repo failure usually means the design has a problem worth pausing for. Easy to flip if it's wrong.
- **Dependency cycle** → terminal: `<!-- ship-epic:event:cycle -->` once (deduped), `CronDelete` the epic's loop, halt.
- **Parent unreadable on consecutive wakes** → `CronDelete` the epic's loop, halt.
- **User @-mention on the parent, ambiguous** → `blocked-user: user-mention-ambiguous`, `CronDelete` the epic's loop, halt (this halt self-cancels like every other terminal path).
- **Any sub-issue `blocked-user` / `external-blocker`** → leave the epic loop running. Other workers can keep making progress; the blocked one waits for the human. Surface in the terminal block but don't halt the epic.

## Locked decisions

Don't re-litigate without a new round of architect review:

1. **Cron-entry match via captured `<command-name>` + permissive regex fallback.** Phase 0's self-arm check reads the slash-command name Claude Code injects at invocation time (e.g. `/abc:ship-epic`) and uses it verbatim in both the cron arming string and the subsequent match check. A permissive regex (`(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-epic`) is the fallback for environments where `<command-name>` isn't reachable. This fixes a real-world correctness bug where hardcoding `/ship-epic` failed to match plugin-namespaced cron entries and caused every wake to duplicate-arm.

## Open questions (deliberately not resolved in v1)

1. **Milestone mode.** Is a milestone-input coordinator worth building? A milestone has no parent issue to aggregate status onto (the candidate target — writing `<!-- ship-epic:* -->` comments on each milestone issue's project — is awkward and unlike every other coordinator surface). v1 **rejects** `milestone:` args at Phase 0 and points the user at `/abc:ship-issue milestone:<uuid>` (the serial walker), mirroring `/ship-epic-gh`. Revisit only if a real need for parallel milestone shipping (not serial) shows up.
2. **Soft merge gates** ("Sub-B can implement but not merge until Sub-A merges"). Would require a new state in `/ship-issue`. v1 only supports hard gates via `blocks`.
3. **Cross-repo package publishes** between sub-issues (Sub-A adds a type in `@company/foo`, Sub-B in another repo consumes it after publish). Out of scope — falls under org Pre-Task Check 1 ("upstream change must happen first"). Coordinator can surface this as a `blocked-user` if it sees a `repo:` dependency that requires a publish step, but the publish itself is manual in v1.
4. **Coordinator wake cadence**: 10 min vs 6 (matching workers). 10 is recommended — the coordinator only matters on a worker `merged` (unblocks downstream) or `failed`/`blocked-user` (epic-level decision). Both events show in Linear within seconds; 10-minute lag is acceptable and keeps cron noise down.
5. **Multiple coordinators on the same parent**: handled, not open — same-session re-invocation no-ops via cron-match; cross-session is caught by the Phase 0 single-session constraint (`possible-duplicate-coordinator` / `parent-already-serial-walked`). One coordinator loop per parent.
6. **Worker death detection**: if a worker's cron silently dies (machine reboot, manual `/loop cancel`), the coordinator will see it as no longer `in-flight` but Linear status hasn't reached terminal — should it re-arm? v1: yes, if the sub-issue is otherwise `ready`-eligible. Re-arming is idempotent at the worker level.

## What this doesn't do

- Doesn't implement code itself
- Doesn't open or merge PRs itself
- Doesn't run tests itself
- Doesn't replace `/ship-issue` — it composes it

## File layout

Shipped under the marketplace plugin layout:

```
plugins/abc/skills/ship-epic/
  SKILL.md      # operational procedure (mirrors /ship-issue style) — authoritative
  DESIGN.md     # this doc — architectural rationale + locked decisions
```

(No `README.md` for this skill; `/ship-issue` is the only one with the full three-file set.)

## Notes

- No new MCP tools needed beyond what `/ship-issue` already uses.
- Key correctness surface: dependency-graph cycle detection (terminal, deduped marker), ready/waiting classification under various blocked-by topologies, idempotent self-arming, and the in-flight match using the **same** namespace-aware worker key as the fire string.
