# ui-reachability — shared helper

Canonical definition of the **UI-reachability check**: after implementing a change,
ensure any newly-added user-facing surface is reachable from the existing UI, or that the
ticket/issue carries an explicit note telling a human validator how to reach it.

**Consumed by:** `ship-issue`, `ship-issue-gh`. Each consumer references this file from
its `pending → implementing` step 4 and its `implementing (resume)` handler rather than
restating the check.

---

## Parameters

| Parameter | Meaning | Per-consumer value |
|---|---|---|
| `<tracker-comment>` | how option (b) posts its validation note | `ship-issue`: a `<!-- ship-issue:note:reachability -->` **Linear comment on the ticket** · `ship-issue-gh`: a `<!-- ship-issue:note:reachability -->` **comment on the issue** |
| `<PR-or-MR>` | the artifact opened after this check | `ship-issue`: the PR/MR · `ship-issue-gh`: the PR |

## The check

After implementing and running local checks, scan the diff for new files under
conventional UI-surface paths:

- `src/pages/**` (Next.js Pages Router, Astro, Nuxt)
- `pages/**` at repo root (older Next.js, similar)
- `src/routes/**` and `routes/**` (SvelteKit, SolidStart, Remix, TanStack Router)
- `app/**` paired with a framework router (Next.js App Router, Remix v2)
- `src/views/**` (Vue / older conventions)
- Framework-specific equivalents — use the same heuristic: any path the framework's
  routing convention treats as a user-reachable route.

**If at least one new UI-surface file was added**, take exactly one of the following
actions before opening the `<PR-or-MR>`:

a. **Wire an entry-point.** Add a link in the existing nav, mark up an index/landing page
   to reference the new surface, or otherwise ensure a human navigating the existing UI
   can reach the new surface without knowing the URL out-of-band.

b. **Inline a validation note.** If the surface is deliberately orphan (admin-only utility
   route, deep-link debug page, intentionally-unlinked) or the framework lacks a natural
   entry-point, post `<tracker-comment>` stating exactly how a human should reach the new
   surface during `## Validation` — e.g. *"feature is not reachable from existing UI;
   navigate to `/foo` directly to verify."*

**Pure-backend changes** (only files outside the UI-surface conventions — `src/lib/`,
`src/api/`, `src/server/`, `internal/`, library code, infra, migrations, docs) **skip this
step entirely.** No entry-point needed; no validation note required.

**Detection is heuristic** and may misfire — when ambiguous (a path that matches a
UI-surface pattern but isn't actually user-reachable, e.g. a `pages/_app.tsx` framework
shell, a non-route module under `app/`, or a route gated by feature-flag), err toward (b)
— write the validation note rather than fake-wiring an entry-point. The cost of an
unnecessary note is one extra comment; the cost of a missing note is a manual validation
that quietly skips the new surface.
