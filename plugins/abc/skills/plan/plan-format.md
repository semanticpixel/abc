# plan-format — the PLAN-*.md grammar

Canonical grammar for the `PLAN-*.md` documents `/abc:plan` emits and the scaffold
skills consume. Single-sourced here so the producer and both parsers can't drift.

**Authored by:** `/abc:plan`. **Consumed by:** `/abc:scaffold-sub-issues` (Linear) and
`/abc:scaffold-sub-issues-gh` (GitHub). Each scaffold parses per this doc and keeps only
its tracker-specific deltas inline (Linear labels/relations vs GitHub labels/task-list).

---

## Two formats — prefer strict, accept loose

A parser tries the strict format first and falls back to loose. If **neither** matches,
halt with: "I couldn't parse sub-tasks from this plan. Expected `### ST-N:` blocks or
`## Sub-issue N — <repo>:` headings."

### Strict format (`/abc:plan` output) — preferred

Top-level sections:

- **Title** — the H1 minus the leading `PLAN:`.
- **Context** — section text.
- **Approach** — section text.
- **Sub-tasks** — one `### ST-N: <title>` block per sub-task (see grammar below).
- **Validation** — top-level section text (parent-level notes; see gate rules below).
- **Out of scope** — section text.

**Sub-task block grammar.** For each `### ST-N: <title>`:

| Field | Bullet | Required | Value |
|---|---|---|---|
| repo | `- **repo:** <name>` | yes (error if missing) | a `repo:` label / workdir name; cross-owner allowed as `<owner>/<name>` |
| scope | `- **scope:** <text>` | yes | 1–2 sentences |
| acceptance criteria | `- **acceptance criteria:**` + nested bullets | yes | one or more bullets |
| validation | `- **validation:** <steps>` | optional | per-sub-task manual-validation gate — see below |
| blocks | `- **blocks:** <list>` | optional | relations sentinel (below) |
| blocked by | `- **blocked by:** <list>` | optional | relations sentinel (below) |

### Loose format — fallback

For plans not produced by `/abc:plan` (hand-written or `~/.claude/plans/*.md` drafts):

- Sub-task headings like `## Sub-issue N — <repo>: <title>`. Required: `repo:` (in the
  heading or a first-line tag). Optional scoped sub-sections beneath: `### Description`,
  `### Changes`, `### Acceptance criteria`, `### Tests`, `### Local checks`,
  `### Files to touch`, `## Validation`.
- If a sub-task is missing acceptance criteria, **ask the user** before proceeding —
  better to fix the source than fabricate. Don't auto-fill.

## Relations sentinel (`blocks:` / `blocked by:`)

A relations value is either a comma-separated list of `ST-N` IDs, or an explicit
"no relations" marker. Accept **all** of these as "no relations", case-insensitively:

- `(none)` — the canonical form `/abc:plan` emits
- `(empty)` — legacy / hand-written alias
- the bullet omitted entirely

Do not treat `(none)`/`(empty)` as a literal ST-ID. A parser that has never seen the
sentinel must still degrade to "no edge", never invent an `ST-(none)` node.

## Validation-gate detection (where the manual-validation gate attaches)

The gate drives the post-merge `blocked-verify` halt in `/abc:ship-issue[-gh]`. Resolve it
in this order — first match wins:

1. **A `- **validation:** <steps>` bullet inside a sub-task block** → that sub-task carries
   the gate. This is the strict-format gate carrier and the only way to attach the gate to
   a *specific* child without ambiguity. The bullet's text becomes the child's `## Validation`
   section body.
2. **A `## Validation` heading inside a sub-task's body** (loose format) → that sub-task
   carries the gate.
3. **A top-level `## Validation` section** → unattached. The scaffold asks in its preview
   phase which sub-issue should inherit it (default: the last UI-touching sub-task if
   detectable, else "none"). A top-level section is parent-level notes until assigned —
   it never silently attaches to a child.

If both a sub-task `validation:` bullet (1/2) and a top-level section (3) are present, the
per-sub-task gate wins for that child and the top-level text stays as parent-level notes.
