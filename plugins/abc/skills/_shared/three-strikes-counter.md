# three-strikes-counter — shared helper

Canonical definition of the **three-strikes CI counter**: the escape hatch that stops a
worker from looping forever on the same failing assertion check. After three failed fix
attempts against the same check, the worker hard-stops to `failed` instead of burning
wakes indefinitely.

**Consumed by:** `ship-issue`, `ship-issue-gh`. Each consumer references this file from
its Phase 3.5 escape-hatches section rather than restating the counter.

---

## Parameters

| Parameter | Meaning | Per-consumer value |
|---|---|---|
| `<failing-bucket>` | how Phase 3 marks a check "failing" | `ship-issue`: GitHub `bucket=fail` / GitLab `failed` · `ship-issue-gh`: `bucket=fail` |
| `<passing-bucket>` | how Phase 3 marks a check "passing" (drives the reset) | `ship-issue`: GitHub `bucket=pass` / GitLab `success` · `ship-issue-gh`: `bucket=pass` |
| `<failcount-key>` | the per-check key in the marker | `ship-issue`: `<platform>:<check-name>` (e.g. `github:ci/test`, `gitlab:build/compile`) · `ship-issue-gh`: `github:<check-name>` (GitHub-only — no platform variation) |

The marker namespace is `ship-issue:` for both consumers. The per-check "assertion vs
infra" reclassification and the stale-CI freshness guard are defined in each consumer's
Phase 3 rows 3a/3b supporting rules; this counter reads their result, it does not
re-derive it.

## Ownership

Owned entirely by Phase 3.5. Phase 3 and Phase 4 never read or write
`<!-- ship-issue:failcount:... -->` comments; only Phase 3.5 does. Runs on **every wake**
(including `pr-open` and `merged` wakes — the reset step below depends on that).

## Sub-phase A: reset scan — runs first, unconditionally

1. Comments are **append-only**, so for each `<failcount-key>` take only the **latest**
   `<!-- ship-issue:failcount:<key>=N -->` comment (the most recent by timestamp) — never
   "any comment with N>0", which would re-fire the reset forever. Consider a key live
   only when its latest failcount comment has `N > 0`.
2. For each such live key (e.g. `github:ci/test`): look at the current CI data gathered in
   Phase 3. If a check with exactly that name now passes (`<passing-bucket>`), append a
   `<!-- ship-issue:failcount:<key>=0 -->` comment to record the reset.
3. A key with no matching check in the current data (check renamed, removed, or the PR has
   no CI run yet) is **not** reset — leave it. The counter only resets on an observed
   pass.

Sub-phase A runs regardless of derived state. It's how the counter ever goes back down: a
subsequent wake observes the same check passing and records `=0`.

## Sub-phase B: increment / hard-stop — conditional on this wake's state

Fire **once per wake**, in this order:

1. If Phase 3's derived state is not `fixing`, stop. If it is `fixing` but no CI check is
   in the `<failing-bucket>` of the assertion type (after the per-check reclassification
   from the rows 3a/3b edge-case rules, including the stale-CI freshness guard — i.e. no
   fresh assertion-style checks are currently failing, regardless of which row derived
   `fixing`), also stop. Either way, there is no increment to perform this wake.
2. Identify the failing assertion check(s). For each:
   - Key: `<failcount-key>` (exact string match on subsequent wakes).
   - Read the most recent `<!-- ship-issue:failcount:<key>=N -->` comment. If none, `N = 0`.
3. If `N + 1 >= 3` for **any** of the failing assertion keys → **override** the Phase 3
   state to `failed` with reason `ci-three-strikes:<key>`. Run the `failed` handler
   (Phase 4 § failed) directly and halt. Do not run any other Phase 4 handler.
4. Otherwise, hand control to the `fixing` handler and let it run to completion. **After**
   the `fixing` handler reaches its step 6 (the explicit success signal — the fix commit
   has pushed cleanly and no `blocked-user`/`failed` transition intervened), append a
   single new `<!-- ship-issue:failcount:<key>=N+1 -->` comment per currently-failing
   assertion key. Never increment twice in one wake, even if the `fixing` handler
   encounters additional failures mid-run. If `fixing` escapes to `blocked-user`/`failed`
   before reaching step 6, do **not** write any increment.
