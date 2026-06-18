# skill-commit-marker — shared helper

Canonical definition of (a) **"the last skill commit"** — how the worker skills locate
the most recent commit they authored on a PR/MR branch (the anchor for "review comments
created *after* the last skill commit" in the Phase 3 state table) — and (b) the
**marker conventions every skill commit must carry**.

**Consumed by:** `ship-issue`, `ship-issue-gh`. Each consumer references this file from
its Phase 3 supporting rules and from its commit steps (`pending → implementing`,
`fixing`) rather than restating the rule.

---

## Parameters

| Parameter | Meaning | Per-consumer value |
|---|---|---|
| `<pr-branch>` | the open PR/MR's head branch | derived per the consumer's Phase 4 (`gitBranchName` for `ship-issue`; the `<n>-<kebab-title>` prefix for `ship-issue-gh`) |

The HTML marker namespace is `ship-issue:` for **both** consumers (the GitHub sibling
deliberately reuses the Linear marker namespace so the conventions stay identical).

## Defining "the last skill commit"

Used by Phase 3 rows 3 / 3a / 3b / 4. It is the most recent commit on `<pr-branch>`
carrying the skill's commit marker. Check the `<!-- ship-issue:commit -->` HTML comment in
the commit body first — this is the primary marker, written on every skill commit (see
**What to write** below). Fall back to the legacy `Co-Authored-By: Claude` trailer for
commits made before the HTML marker landed (or where a human pushed the initial commits
without either marker):

```
git -C <workdir> log <pr-branch> --grep="<!-- ship-issue:commit -->" -1 --format="%H %ai"
# if empty, fall back to the legacy trailer:
git -C <workdir> log <pr-branch> --grep="Co-Authored-By: Claude" -1 --format="%H %ai"
```

If neither marker exists on the branch, treat **all** open review comments as new.

## What to write on commits

- **Always** include a `<!-- ship-issue:commit -->` HTML comment line in the commit body.
  Anchors the lookup above and is scoped under the existing `<!-- ship-issue:* -->`
  namespace, so it doubles as a Skill-authored audit signal in `git log`.
- **By default**, also include a `Co-Authored-By: Claude <noreply@anthropic.com>` trailer
  (exact string) for backward-compat with historical skill-commit detection.
- **Skip the trailer** when any reachable `CLAUDE.md` forbids it. Detection: use the
  `Grep` tool (case-insensitive, `-i`) for the pattern `co-authored-by` across the
  workdir's `CLAUDE.md`, any ancestor `CLAUDE.md` walking up to `/`, and
  `~/.claude/CLAUDE.md` — any hit ⇒ skip the trailer (the HTML marker alone is
  sufficient). The heuristic is intentionally conservative — a false positive only omits
  a redundant trailer, while a false negative would violate a documented policy. One-shot
  detection: a single `Grep` call with `-i`, `pattern: "co-authored-by"`, scoped to the
  reachable `CLAUDE.md` paths; any match ⇒ skip the trailer.
