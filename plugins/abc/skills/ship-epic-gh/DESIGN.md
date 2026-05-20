# ship-epic-gh — Design

Status: **Approved** — mirrors the Linear `ship-epic` design with GitHub-Issues-specific adaptations.

The coordinator pattern, worker fan-out via independent `/loop` entries, dependency-graph cycle detection, and "do not halt on `blocked-user`" rule are all lifted verbatim from [`../ship-epic/DESIGN.md`](../ship-epic/DESIGN.md) — read that for the universal rationale. **This file documents what changes for the GitHub-Issues case.**

## Purpose

Coordinator for a GitHub **parent issue** whose children live in a managed `## Sub-issues` task-list. Spawns one `/ship-issue-gh` loop per ready child, gates blocked children until their dependencies merge, and aggregates status into the parent.

Same motivation as the Linear sibling: a multi-repo epic with N independent children runs serially through `/ship-issue-gh` because the worker walks its list one issue at a time. `/ship-epic-gh` makes the genuinely-parallel parts actually parallel.

## Relationship to /ship-issue-gh

- `/ship-issue-gh` is the **worker**. Each ready child runs in its own `/loop 6m /ship-issue-gh <owner>/<repo>#<n>` — independent cron entry, independent state machine, independent comments. Unchanged.
- `/ship-epic-gh` is the **coordinator**. It doesn't implement code or open PRs directly; it manages which workers run, when, and aggregates their status into the parent.
- Workers don't know they're part of an epic. They report state to GitHub (label transitions, PR URLs, `<!-- ship-issue:* -->` comments) just like single-issue runs. The coordinator reads that same state.

The design deliberately preserves `/ship-issue-gh`'s existing contract — no flags, no parallel mode, no state-machine changes. The coordinator composes it.

## Why a parallel skill, not a tracker abstraction inside `ship-epic`

Same locked decision as `ship-issue-gh`. The two backends (Linear typed relations vs GitHub label/task-list emulation) have different data shapes; the cleanest factoring is a focused per-tracker skill. Duplication is constrained to data-access and graph-source.

## Inputs

Only one shape: **`<owner>/<repo>#<n>`** — a GitHub issue whose body contains a managed `## Sub-issues` task-list (the structure `/abc:scaffold-sub-issues-gh` produces).

**Not supported** (deliberate, see open questions):

- Bare `#<n>` (no cwd-derived repo for the parent) — too easy to misroute, and the coordinator runs over a long horizon where cwd may change. Always pass the fully-qualified ID.
- `milestone:<owner>/<repo>/<num>` — milestones are flat in GitHub, not hierarchical. There's no aggregation target. For "ship every issue in this milestone," use `/abc:ship-issue-gh milestone:...` (the serial walker).
- Comma-separated lists — same as above; no aggregation target.
- Linear IDs — wrong family; use `/abc:ship-epic`.

If the parent has no fenced `## Sub-issues` block → reject and point the user at `/abc:scaffold-sub-issues-gh`.

## Hierarchy source: task-list, not native relations

The Linear sibling reads sub-issues via `list_issues parentId=...`. GitHub has no native sub-issue API, so the hierarchy lives in the parent body between the `<!-- ship-epic:sub-issues:start/end -->` fence markers. **The fence is sacred** — the skill only reads and edits content between the markers; everything outside is user-authored.

Implications:

- The skill must re-parse the parent body on every wake (not just once at start). A human reorder or addition takes effect on the next 10-minute tick.
- GitHub auto-toggles `[ ]` → `[x]` when the referenced child issue closes. The skill **does not** manage the checkbox state — it reads it as input but doesn't write it.
- If the user deletes the fence markers (intentionally or otherwise), the skill halts with `blocked-user` rather than re-injecting them. Re-injection at runtime is the kind of "clever" the design refuses; the user runs `/abc:scaffold-sub-issues-gh` again or manually re-fences.

## Dependency graph: label-based

The Linear sibling reads `blocks` / `blocked by` typed relations. GitHub has no typed relations, so we use per-edge labels on the child issues (per `../scaffold-sub-issues-gh/github-conventions.md`):

- `blocks:#<N>` on child A means "A blocks N."
- `blocked-by:#<N>` on child A means "A is blocked by N."
- Cross-repo: `blocks:<owner>/<repo>#<N>` / `blocked-by:<owner>/<repo>#<N>`.

The skill **unions both directions** when building the graph: a `blocks:#A` on B and a `blocked-by:#B` on A are the same edge, deduplicated. This matters because `/abc:scaffold-sub-issues-gh` writes both halves redundantly for safety, and we don't want phantom double-edges.

Cycle detection: identical DFS algorithm as the Linear sibling. Cycle → halt the epic, refuse to fire workers, write `<!-- ship-epic:event:cycle -->` on the parent.

## State machine (per child) — derived, not stored

| State | Source |
|---|---|
| `merged` | `state=closed`, `stateReason=completed` (auto from PR's `Closes` trailer) — or `<!-- ship-issue:event:merged -->` comment from worker |
| `failed` | `state=closed`, `stateReason=not_planned` — or `<!-- ship-issue:event:failed -->` comment |
| `blocked-user` | `<!-- ship-issue:event:blocked -->` with no subsequent `event:resumed` |
| `external-blocker` | `blocked-by:` label points outside the parsed child set, and that referenced issue isn't merged |
| `in-flight` | `CronList` contains `/ship-issue-gh <owner>/<repo>#<n>` |
| `ready` | All in-set `blocked-by:*` upstreams `merged`, no in-flight cron, `state=open` |
| `waiting` | One or more in-set upstreams not yet `merged` |

Same shape as the Linear sibling; only the source rows differ.

## Locked decisions

Don't re-litigate without a new round of architect review:

1. **10-minute coordinator cadence**, 6-minute worker cadence — same as Linear sibling.
2. **GitHub Issues + the workers' marker comments are the sources of truth; skill is stateless.**
3. **Coordinator does not implement code, open PRs, or modify worker state.** Composes the worker; doesn't replace it.
4. **`<!-- ship-epic:status -->` comments are append-only.** GitHub's edit-history isn't reliably exposed; appended snapshots are the audit trail.
5. **Halt on any child `failed`.** Cross-repo failures usually mean the design has a problem worth pausing for. Same call as the Linear sibling; same easy flip if it's wrong in practice.
6. **Do not halt on `blocked-user`.** Other workers may still be progressing.
7. **Single host per invocation.** Cross-host (github.com + Enterprise) is rejected at Phase 0.
8. **Only accept fully-qualified parent IDs.** No bare `#<n>`, no comma-lists, no milestones at the coordinator level.

## Open questions (deliberately deferred)

1. **Soft merge gates** ("B can implement but not merge until A merges"). Would require a new state in `/ship-issue-gh`. v1 only supports hard gates via `blocked-by:*`.
2. **Native sub-issues API.** GitHub has hinted at hierarchy work in their roadmap. If it ships, replace the task-list-in-body pattern with native calls (simpler, richer UI). The skill's external interface doesn't change.
3. **Cross-host coordination.** v1 rejects. If a real cross-host epic shows up (github.com parent, Enterprise children, or vice versa), revisit.
4. **Worker output streaming.** The Linear sibling notes that visibility is via Linear status + terminal aggregation, not live agent output. Same trade-off here — the workers' state surfaces in GitHub issue comments, which the user can `gh issue view` directly. A live tail would be nice but requires plumbing the loop fan-out doesn't expose.
5. **`gh project` integration.** Projects V2 has its own status column that could replace the `status:*` label scheme. Skipped for v1 — label-based works without per-project board setup. Revisit if labels become noisy at scale.

## Review checklist (for the architect-role reviewer)

- [ ] Hierarchy source (task-list parsing between fence markers) is robust to user edits outside the fence.
- [ ] Dependency-graph edge unioning is correct — a `blocks:#A` on B and a `blocked-by:#B` on A produce exactly one edge.
- [ ] DFS cycle detection halts before any worker is fired.
- [ ] Worker fan-out via `Skill(skill: "loop", args: ...)` matches the cron-arming contract `/abc:ship-issue-gh` expects.
- [ ] `<!-- ship-epic:status -->` comments are append-only across all terminal paths.
- [ ] `CronDelete` is called on both the epic's loop AND every in-flight worker loop in the `failed` path.
- [ ] The "do not halt on `blocked-user`" rule survives all the branches (Phase 5 doesn't accidentally halt on the wrong terminal).

## What this doesn't do

- Doesn't implement code itself.
- Doesn't open or merge PRs itself.
- Doesn't run tests itself.
- Doesn't replace `/ship-issue-gh` — it composes it.
- Doesn't manage the task-list checkbox state in the parent body — GitHub handles that natively when children close.
- Doesn't support milestones, comma-lists, or bare `#<n>` parents — those are intentionally rejected at Phase 0.
