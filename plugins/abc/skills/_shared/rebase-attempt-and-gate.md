# rebase-attempt-and-gate — shared helper

Canonical definition of the **rebase-against-base attempt-and-gate** escape hatch: when a
PR/MR branch falls behind its base (typically after a parent or sibling PR merges during a
parallel epic run), attempt an automatic rebase, gate it on the project's checks, and
escalate to `blocked-user` — never `failed` — when a human is genuinely needed.

**Consumed by:** `ship-issue`, `ship-issue-gh`. Each consumer references this file from
its Phase 3.5 escape-hatches section rather than restating the flow.

---

## Parameters

| Parameter | Meaning | Per-consumer value |
|---|---|---|
| `<behind-base-signal>` | how Phase 3 detects "behind base" | `ship-issue`: GitHub `mergeStateStatus=BEHIND` / GitLab a non-zero behind/diverged commit count from `glab mr view` · `ship-issue-gh`: `mergeStateStatus=BEHIND` on the open PR |
| `<command>` | the slash command a human re-runs to resume | `/abc:ship-issue` · `/abc:ship-issue-gh` |

**Behind-base is detected from `<behind-base-signal>` gathered in Phase 3** — it is the
trigger for this section; do not re-fetch.

## The flow

1. `git fetch origin && git rebase origin/<base>`.
2. **Conflict markers present** → `git rebase --abort`. Transition to `blocked-user` with
   reason `rebase-needs-human`. The marker comment lists the conflicted file paths so the
   human can resolve locally and push.
3. **Rebase clean (no markers)** → run the project's gates — the same local checks Phase 4's
   handlers run (`pnpm typecheck && pnpm test` or whatever the repo's `package.json`
   scripts / CLAUDE.md defines).
4. **Gates pass** → `git push --force-with-lease`. Post `<!-- ship-issue:rebase:auto -->`
   as a **marker-only** comment — the marker is the entire comment body, no trailing
   prose. Matches the convention of the other `<!-- ship-issue:* -->` markers (e.g.
   `<!-- ship-issue:commit -->`): downstream skills (`/abc:review-sweep` health pre-pass
   and the CI-repair pre-pass) grep for the marker as a yes/no signal, and free-form prose
   breaks the match across revisions. The rebase SHA range is already captured in the
   commit log for forensic reading. If a human-readable timeline note is also wanted, post
   it as a *separate* PR comment that does NOT contain the marker so the two signals stay
   decoupled. Re-enter Phase 3 on the next wake.
5. **Gates fail** → `git rebase --abort`. Transition to `blocked-user` with reason
   `rebase-clean-but-tests-failed`. The marker comment summarises the failing gate output
   (top ~20 lines is enough).
6. The **self-cheating hard stop** applies verbatim inside this flow. No `--no-verify`, no
   `.skip()`-ing tests, no `// @ts-expect-error` to silence a failure, no widening types —
   even when auto-resolving. If the only way to make gates pass is to delete or weaken an
   assertion, abort and escalate via step 5.

The legacy `failed: rebase-conflict-needs-human` reason is **no longer emitted**.
Mechanical rebase failures are recoverable by re-running `<command> <same-arg>` after
resolving the conflict locally and pushing — so they belong on the `blocked-user` axis,
not `failed`. Note the cron does **not** stay armed across a `blocked-user` halt: Phase
7's CronDelete fires on **all** halts (blocked-user, failed, all-merged), so re-running
the command is what re-arms the loop. `failed` is reserved for self-cheating and hard
correctness walls (see the self-cheating hard stop and the three-strikes counter).
