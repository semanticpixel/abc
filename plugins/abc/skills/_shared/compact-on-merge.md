# compact-on-merge — shared helper

Canonical documentation for the **compact-on-merge** convention: triggering Claude Code
conversation compaction at the natural terminal boundary of a shipped sub-issue, so
long-running shipping loops stay under context budget without ad-hoc user-driven
`/compact` interruptions.

**Consumed by:** `ship-issue`, `ship-issue-gh`, `ship-epic`, `ship-epic-gh` (and the
planned `review-epic` / `review-epic-gh` skills). Each consumer's SKILL.md references
this file at its trigger point rather than duplicating the rules — edit the convention
here, in one place.

---

## When (the trigger boundary)

**Workers** (`ship-issue`, `ship-issue-gh`): inside the `merged` handler, **after** the
terminal state is written to the tracker (status transition + `<!-- ship-issue:event:merged -->`
comment posted) and **before** advancing to the next item in the list. Fire only when at
least one **non-terminal item remains** in this invocation's queue — when the merged item
was the last, the loop is about to self-cancel and print its summary; compacting buys
nothing.

**Coordinators** (`ship-epic`, `ship-epic-gh`): at the **end of a wake that observed one
or more children newly reach `merged`**, after the `<!-- ship-epic:status -->` aggregation
comment is posted and before the wake returns. "Newly merged" is derived statelessly from
the tracker: a child counts as newly merged when the most recent **prior**
`<!-- ship-epic:status -->` comment did not list it as `merged` (or no prior status
comment exists). Same last-item rule: when the wake is terminal (all merged → epic
closing), skip — the loop is ending anyway.

**At most once per wake.** Two children merging in the same coordinator wake, or a worker
advancing past one merged item to start the next, still produce exactly one compaction
prompt.

## What persists (why compacting here is safe)

The shipping skills are **stateless across sessions by design** — every wake re-derives
state from the tracker. Nothing load-bearing lives only in the conversation:

| Survives compaction | Where it lives |
|---|---|
| Issue/PR state, `status:*` labels, marker comments, failcount counters | The tracker (Linear / GitHub Issues) — re-read on every wake |
| The armed `/loop` cron entry + its raw arg string | The harness scheduler, outside the conversation |
| Branches, commits, the merged PR | git / the platform |
| The next sub-issue's spec | Its tracker issue body — the next wake's Phase 1 fetch reads it fresh |

What's discarded is exactly the bulk: the merged item's diffs, test output, review
threads, and fix iterations — all already persisted in the PR and no longer needed. The
post-compaction wake behaves identically to a fresh-session resume, which the skills
already support ("closing the terminal mid-loop is safe").

## How (mechanism decision + fallback chain)

Researched 2026-06: how can a skill trigger compaction from inside its workflow?

1. **Direct SDK call — NOT AVAILABLE.** There is no `compact()`-equivalent tool, Agent
   SDK method, or control request the model can invoke. `/compact` is strictly a
   user-typed built-in CLI command; the Skill tool explicitly excludes built-in commands.
2. **Skill-runtime sentinel — NOT AVAILABLE.** No marker/JSON field a skill can emit that
   the harness interprets as a compaction request. `PreCompact` / `PostCompact` hooks
   *react* to compaction (and can inject context or block), but cannot *trigger* it.
3. **Documented user-action prompt — SHIPS (v1).** Print the compaction prompt (exact
   format below) and trust the user. Worse UX than automatic, but available today.

**Decision: ship (3), document (1)/(2) as the upgrade path.** When Claude Code grows a
programmatic trigger (the capability is a known feature request upstream), swap step (3)
for it here — consumers reference this file by name, so the upgrade is a one-file change.

**Backstop:** Claude Code's built-in auto-compaction still fires when context fills,
regardless of this convention. Because the skills are stateless (table above), an
auto-compact at an *arbitrary* point is also safe — the merge boundary is simply the
*best* point, which is why the prompt nudges the user there.

### The prompt format

Workers, in the `merged` handler:

```
🗜 Sub-issue <ref> merged. Run /compact now to free context before picking up <next-ref>.
```

Coordinators, at end-of-wake:

```
🗜 <n> child(ren) merged this wake. Run /compact now to free context before the next coordinator wake.
```

`<ref>` / `<next-ref>` are the tracker IDs (`PROJ-66`, `<owner>/<repo>#43`). Print the
line as the **last** output of the wake, after the Phase 8 status block, so it's the
thing the user sees at the prompt.

## `--no-compact` (opt-out flag)

Every consumer accepts a trailing `--no-compact` flag on its argument string:

```
/abc:ship-issue PROJ-89,PROJ-90 --no-compact
/abc:ship-epic-gh <owner>/<repo>#100 --no-compact
```

- **Parsing:** detect and strip `--no-compact` from `$ARGUMENTS` *before* shape
  detection (it would otherwise corrupt ID/URL/milestone matching). When present, set
  no-compact mode for this invocation: skip the compaction prompt entirely at every
  trigger boundary. Nothing else changes.
- **Raw-arg retention:** the flag stays in the **raw arg string** used for cron
  arming/matching (`/loop 6m <command-name> <raw-arg>`). The skills persist nothing
  locally, so the cron entry's arg string is the only carrier — keeping the flag there
  is what makes the opt-out survive every subsequent wake. Stripping it from the raw
  arg would silently re-enable compaction prompts on wake 2.
- **Coordinator → worker propagation:** coordinators invoked with `--no-compact` append
  it to every worker they fire: `Skill(skill: "loop", args: "6m /abc:ship-issue <SUB-ID> --no-compact")`.
  The user opted the whole epic out; workers inherit.
