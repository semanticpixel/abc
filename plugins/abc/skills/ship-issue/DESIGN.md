# ship-issue — Design

Status: **Approved**, amended 2026-04-23 — added platform detection (GitHub/GitLab) and multi-repo invocation via Linear labels.

This doc exists so that humans critique the approach before any skill code is written. Once reviewed and merged, the implementation ticket picks up against these decisions.

**Terminology note**: "PR" in this doc means *pull request (GitHub) or merge request (GitLab)* — same concept, different platform verb. The skill always uses the platform-correct term in actual operations.

## Purpose

Drive a Linear issue (or list, or parent with sub-issues) from **Backlog** to **Done** through the implement → PR → address-review → merge loop, autonomously. Invoked as `/ship-issue <arg>`. Codifies the pattern we ran manually for PROJ-83..86.

## Non-goals

- Writing net-new Linear issues or breaking epics into sub-tasks (user's job).
- Making architectural decisions not scoped in the ticket.
- Replacing human review. Code review still happens; the skill addresses review comments but does not merge over objection.
- Auto-verifying UI changes. That's Phase C (`/verify-ticket`); `ship-issue` only defers to it.

## Input

`<arg>` accepts:

- A single ticket ID: `PROJ-88`
- A Linear URL: `https://linear.app/<workspace>/issue/PROJ-88`
- A **parent issue ID** — the skill resolves its sub-issues and walks them in Linear's default order
- A **comma-separated list** in desired order: `PROJ-65,PROJ-66,PROJ-67`
- A **project milestone**: `milestone:<uuid>` — skill expands to the milestone's non-terminal issues, ordered by `createdAt` ascending

If the arg is a parent issue with no sub-issues, treat it as a single ticket. If it's a list, the user's order is respected — the skill does not re-prioritise.

**Parent issues are the natural multi-repo pattern.** When a change spans multiple repos (e.g. a feature that needs a server-side change in one repo and a client-side change in another), the user breaks the parent issue into one sub-task per repo and labels each sub-task with its target repo (see "Platform and repo discovery" below). Sub-tasks serialise — if A must merge before B, the user orders them that way in Linear.

**Milestones are the natural phase-of-work pattern.** When all issues under a project milestone (e.g. "Phase 2 — Feedback Reporter (Linear)") need to be shipped as a batch, the user passes `milestone:<uuid>` and the skill walks them. Resolution is: `list_milestones` → find the UUID → extract its project → scoped `list_issues(project=<that>)` with pagination → client-side filter by `projectMilestone.id`. This keeps the query bounded; an unscoped "find this UUID anywhere in the workspace" query would silently truncate on any workspace with more issues than the page limit. Invalid UUID or all-terminal milestones → `blocked-user` before the cron arms (no silent empty-loops).

Ordering is `createdAt` ascending, which matches the common case of creating tickets in intended work-order. **Caveat**: if the user later drags tickets around in Linear's milestone view, the skill won't follow the manual reorder — the MCP's `list_issues` doesn't expose `sortOrder` on issues. Workaround for reordered milestones is to pass the tickets as an explicit comma-separated list in the desired order.

The raw arg string retained for the cron-entry match rule is the original `milestone:<uuid>` form, not the expanded list. That way re-invoking with the same milestone is idempotent (one loop per milestone), and new issues added to the milestone mid-flight get picked up on the next wake's re-derivation.

## Platform and repo discovery

The skill is platform-agnostic: it can drive GitHub repos (via `gh`) and GitLab repos (via `glab`). It also supports multi-repo invocations by convention rather than configuration.

### Per-item label resolution

The **same rule applies to every input shape** — single ticket, comma-separated list, or parent with sub-tasks. For each item the skill is about to work on:

1. Does the item have a `repo:<name>` label? → resolve `<name>` to a subdirectory of cwd and work there.
2. No label? → fall back to the current git repo of the invocation cwd.

Mixing is allowed: some items in a list can have `repo:` labels and others not. Each is resolved independently. This means a comma-separated list of tickets that all live in one repo doesn't need any labels — just `cd` into that repo and run the skill. A list of tickets spanning multiple repos labels each one explicitly.

Platform is detected from the resolved repo's origin:

```
git remote get-url origin
  → contains "github.com"    → use `gh`
  → contains "gitlab.<host>" → use `glab`
  → anything else            → blocked-user (unknown platform)
```

### Multi-repo example

When the invocation arg is a parent issue whose sub-tasks span repos, the user typically invokes from a parent directory containing each repo as a subdirectory:

```
cwd: <workspace>/
├── repo-a/              ← has git remote pointing at GitLab
├── repo-b/              ← has git remote pointing at GitHub
└── repo-c/              ← has git remote pointing at GitHub
```

Each sub-task gets a `repo:<name>` label matching one of the subdirs. The per-item resolution rule above then applies to each sub-task independently.

### Blocked-user triggers specific to repo discovery

- Item has a `repo:<name>` label whose `<name>` doesn't match any subdirectory of cwd.
- Item has **multiple** `repo:` labels. One item = one repo; if a change truly needs two repos in a single unit, the user needs to split it.
- Item has **no** `repo:` label AND the invocation cwd is not itself inside a git repo (i.e. there's no fallback).
- Detected platform is neither GitHub nor GitLab.

## State machine (per ticket)

```
pending ──▶ implementing ──▶ pr-open ──▶ merged ──▶ (advance to next)
                                │
                  ┌─────────────┼───────────────┐
                  ▼             ▼               ▼
                fixing     blocked-user    blocked-verify
                  │             │               │
                  └─▶ pr-open   │         ┌─────┘
                                │         ▼
                                │    (pass) merged
                                │    (fail) fixing or blocked-user
                                ▼
                             (terminal: halt loop)
                             failed ◀─── hard error
```

| State | Meaning | Linear status |
|---|---|---|
| `pending` | Ticket selected, not yet worked | Backlog / Todo (unchanged) |
| `implementing` | Writing code + running tests locally | In Progress |
| `pr-open` | PR created, waiting for CI + reviews | In Review |
| `fixing` | Addressing review comments | In Progress |
| `blocked-user` | Ambiguity or judgment call — wait for human | In Review (+ Slack ping, Phase B) |
| `blocked-verify` | `## Validation` present, auto-verify pending (Phase C) | In Review |
| `merged` | PR merged | Done |
| `failed` | Hard error — halt | Canceled (with explanation comment) |

### Transitions — who initiates

| From → To | Initiator | Trigger |
|---|---|---|
| `pending → implementing` | skill | start of loop |
| `implementing → pr-open` | skill | PR created |
| `pr-open → fixing` | skill | code-review-bot or reviewer comment detected |
| `fixing → pr-open` | skill | fix commit pushed |
| `pr-open → merged` | GitHub / GitLab | PR/MR merged (detected by polling) |
| `pr-open → blocked-user` | skill | see triggers below |
| `any → blocked-verify` | skill | ticket body contains `## Validation` and it's not yet passed |
| `blocked-verify → merged` | Phase C skill | `/verify-ticket` returns ✅ |
| `blocked-verify → fixing` / `blocked-user` | Phase C skill or human | ❌ result |
| `any → failed` | skill or user | hard error, see escape hatches |

## Polling cadence

**6-minute fixed interval** for `pr-open` and `blocked-verify`. Chosen empirically from PROJ-83..86. Slight cache-miss cost per wake is acceptable at that rate; shorter intervals burn cache without informational gain.

No separate heartbeat — the poll itself verifies nothing is stuck.

### Self-arming (load-bearing)

The user invokes `/ship-issue <arg>` once. The skill itself is responsible for arming the `/loop` that fires subsequent wakes — the user should **never** need to type `/loop 6m /ship-issue ...` explicitly. This is the correctness contract of the skill, not a convenience.

#### Cron-entry match rule

Used by both the arm check (below) and the self-cancel in Stop conditions; the two must stay in lockstep. The rule is single-sourced in [`../_shared/cron-match.md`](../_shared/cron-match.md) — `ship-issue` is the consumer with `<boundary-class>` = alphanumeric, `-`, `,` and `/loop` interval `6m`. SKILL.md § Phase 0.5 references the same file; editing the convention there updates every consumer at once.

#### Arm check

Evaluated at the start of every wake:

1. Call `CronList` to enumerate active scheduled tasks in the current session.
2. Apply the cron-entry match rule above to each entry.
3. If no match → invoke `Skill(skill: "loop", args: "6m <command-name> <raw-arg>")` to arm the cron — substituting the captured `<command-name>` verbatim, not a hardcoded skill name.
4. If a match → no-op. This is the common path on loop-triggered wakes.

The match key is the **full raw arg string**. So `/ship-issue PROJ-89,PROJ-90` is one loop that walks the two tickets in user-specified order. A separate invocation with a different arg — e.g. the user types `/ship-issue PROJ-91` later — gets its own independent cron.

On terminal state (all items `merged`, any item `blocked-user` or `failed`), the skill calls `CronDelete` on its own entry to stop the loop. Combined with the idempotent arm-check above, this makes the skill self-contained: the user never manages the cron.

**Why this matters as a decision, not a detail**: without the self-arming check, the user has to remember the `/loop` wrapper on every invocation, which defeats the whole "invoke and walk away" premise of the skill. This rule was implicit in A.1's Decision #1 ("6-minute fixed polling cadence") but the A.2 implementation dropped it. Making it explicit here so the intent can't drift again.

## Stop conditions

The loop halts when any of:

- All input tickets reach `merged`.
- Any ticket enters `blocked-user` (skill surfaces state + Slack ping; user resumes by re-running the command).
- Any ticket enters `failed`.
- User cancels via a standalone `cancel` Linear comment (case-insensitive, whole-comment-body or first line) — Phase 3's cancel scan detects it and derives `failed: cancel-requested`. (`/loop cancel` remains the manual override.)

In every terminal case — `merged`, `blocked-user`, and `failed` alike — the skill calls `CronDelete` on its own loop entry, identified via the [cron-entry match rule](#cron-entry-match-rule) defined under Self-arming. **CronDelete fires on all halts**, including `blocked-user`: the `/loop` cron stops immediately and the user doesn't have to run `/loop cancel` manually; re-running `/ship-issue <same-arg>` after resolving is what re-arms it.

## Blocked-user triggers

The skill stops and asks, it doesn't guess, when:

- Review comment requests scope outside the ticket's acceptance criteria.
- **Same code-review-bot rule ID / finding-name** appears twice in a row after a fix commit — not the same severity or category, the same *named rule*. If the rule code-review-bot fires is identical after a fix attempt, the fix didn't address the underlying issue and it's likely a design problem the skill can't patch away. (Rule ID is the most precise class definition; severity alone would over-trigger, category alone would under-trigger.)
- CI fails in a non-test-assertion way (env, secrets, deps).
- Rebase against `main` produces conflict markers, or post-rebase gates fail. Both escalate as `blocked-user` (recoverable), not `failed`. See SKILL.md § Rebase against base — attempt-and-gate.
- An **ambiguous, or a redirect/cancel @-mention** of Claude on the PR. **Actionable** @-mentions are handled in the `fixing` handler (canonical); not every @-mention halts.
- Any of the repo-discovery conditions listed under "Platform and repo discovery" (missing/multiple `repo:` labels, unresolvable `<name>`, unknown platform).

## blocked-verify triggers

- Ticket body has a `## Validation` section.
- Pre-Phase C: skill transitions to `blocked-user` with the validation text inlined, so a human runs it.
- Post-Phase C: skill invokes `/verify-ticket <id>`; decision follows the verify skill's result.

## Session-boundary behavior

**The skill keeps no in-memory state across sessions.** Linear, GitHub, and GitLab are the sources of truth. Durable state (e.g. retry counters — see escape hatches) goes in Linear comments using the canonical format `<!-- ship-issue:<category>:<key>=<value> -->`. The skill re-reads its own notes on re-invocation. Example: `<!-- ship-issue:failcount:github:ci/test=2 -->` (see escape hatches for the concrete use).

### Skill-commit marker — dual-mode (HTML primary, trailer fallback)

Phase 3's "last skill commit" lookup is the load-bearing signal that distinguishes "review comments since my last push" from "all open review comments" (relevant on the `fixing` rows). Earlier iterations anchored detection on a `Co-Authored-By: Claude` trailer in the commit message — convenient because git carries trailers across rebases and squashes, but this conflicts with user/repo policies that forbid AI-attribution trailers ("no AI attribution" rules are increasingly common in `CLAUDE.md`).

The skill now anchors detection on an `<!-- ship-issue:commit -->` HTML comment in the commit body. The marker:

- Is not an author attribution, so policies forbidding `Co-Authored-By: Claude` don't apply to it.
- Survives normal squash-merge (the commit body is preserved as the squashed message body) but **not** a rebase-with-fixup-squash that drops the body — that's a pre-existing limitation of any in-body marker, and matches the trailer's failure mode.
- Lives under the existing `<!-- ship-issue:* -->` marker namespace already used for durable Linear-comment state.

The legacy `Co-Authored-By: Claude` trailer is retained as a **fallback** in the Phase 3 lookup so historical commits (already merged or in-flight before the marker landed) continue to be detected. Phase 4 commit handlers write **both** markers by default and drop the trailer only when any reachable `CLAUDE.md` (workdir's, any ancestor walking up to `/`, or `~/.claude/CLAUDE.md`) contains a case-insensitive mention of `Co-Authored-By` — a coarse heuristic that catches "never include `Co-Authored-By`" policies without prose parsing. The conservative bias is intentional: a false positive only omits a redundant trailer (the HTML marker still anchors detection); a false negative would violate a documented policy.

On every invocation the skill re-derives the state-machine state from the tracker + git host, resumes from it, and never resets a ticket that's already in a `started`-type state.

> **State-derivation rules are the single source of truth in SKILL.md Phase 3** (the ordered first-match-wins state table, including the terminal row 0 and the `blocked-verify` row 1a). They are intentionally **not** duplicated here — an earlier copy of the table in this section drifted from Phase 3 and gave contradictory derivations. Read SKILL.md § Phase 3 for the authoritative table.

Closing the terminal mid-loop is safe: re-running `/ship-issue <same-arg>` picks up where it left off. No persistent local state to corrupt.

**If you intentionally want to re-work a ticket that has a closed-unmerged PR**, re-open the PR or close the ticket and re-file. The skill will not silently retry — that's the point of the `failed` transition.

## Escape hatches

### Hard stops (→ `failed`, loop halts)

- **Three consecutive commits fail the same CI check.** Platform-aware:
  - GitHub: "same check" = identical check-run name from the GitHub Checks API (e.g. `ci / test`, `code-review-bot / review`).
  - GitLab: "same check" = identical pipeline job name (e.g. `build/compile`, `test/unit`).
  The counter is persisted in a Linear comment with a platform-scoped key: `<!-- ship-issue:failcount:github:<check-name>=N -->` or `<!-- ship-issue:failcount:gitlab:<job-name>=N -->`. Platform segment prevents collisions if a sub-task graph spans both platforms. Survives session restarts — otherwise a perpetually flaky check could dodge the hard-stop by the user happening to re-invoke between failures. **Counter resets only when the same check passes.** `fixing → pr-open` transitions do *not* reset the counter — that's the exact loop we're trying to catch. Reaching `merged` / `failed` is terminal, so reset is moot.
- Skill catches itself about to bypass a failing check — e.g., `--no-verify`, deleting assertions to make tests pass, relaxing a type. **Hard-stop, no self-healing.** Applies *inside* the rebase attempt-and-gate flow too: a clean rebase that only goes green by deleting an assertion is the cheat, not the fix.

### Soft stops (→ `blocked-user`, loop pauses)

- Scope-creep review comment.
- Rebase against `main` produces conflict markers (`blocked-user: rebase-needs-human`), or post-rebase gates fail (`blocked-user: rebase-clean-but-tests-failed`). Mechanical rebase trouble is recoverable by re-running `/abc:ship-issue <same-arg>` after the human resolves and pushes — the `blocked-user` halt itself CronDeletes the loop (CronDelete fires on all halts), so the re-run re-arms it. See SKILL.md § Rebase against base — attempt-and-gate.
- Direct user message interrupting the loop → skill reads it and changes course or asks for clarification.

## What the skill does NOT do

- **Merge.** The skill **never** runs `gh pr merge` / `glab mr merge` — a human merges. The skill drives the PR/MR to green-and-reviewed and waits; after the PR has been green-but-unreviewed-merge-ready for N=5 consecutive `pr-open` wakes it posts a one-time `<!-- ship-issue:note:merge-nudge -->` marker comment, then keeps waiting. The final merge action is always human.
- Merge when `## Validation` exists and verification hasn't succeeded.
- Silently absorb review comments as scope additions.
- Retry transient failures without surfacing them.
- Modify or weaken tests to pass. If a test is wrong, that's a new ticket.

## Known design tensions

### `Closes` / Linear-magic-close-word races the `blocked-verify` gate on validation-gated tickets

Phase 4's `pending → implementing` step 7 links the PR/MR to the issue. If that link uses a magic close word (`Closes PROJ-88` on GitHub, or Linear's auto-complete-on-merge Magic URL), the tracker auto-completes the issue **on merge** — *before* the next worker wake runs. Phase 3 row 1a is designed to catch the merge and derive `blocked-verify` when the ticket carries a `## Validation` heading and no `<!-- ship-issue:verify:passed -->` comment, but by then the issue is already in its done state and any dashboard treats it as shipped; the validation steps land as a post-mortem rather than a gate.

**Resolution (now in the skill, not a manual workaround):** Phase 4 step 7 detects the `## Validation` heading (same heading-match rule as row 1a) and, when present, **omits the magic close word** — using a non-closing reference (`Refs <owner>/<repo>#<n>` on the GitHub sibling; a plain `Linear: <issue-url>` line here) so the worker controls the close. The `merged` handler transitions the ticket to the done state itself, only after the `blocked-verify` gate passes. (This mirrors the GitHub sibling's `Refs`-vs-`Closes` fix.)

## Decisions locked in this doc

Don't re-litigate in the implementation ticket without a new round of architect review:

1. 6-minute fixed polling cadence.
2. Linear, GitHub, and GitLab are the sources of truth; skill is stateless.
3. User orders the ticket list; skill does not re-prioritise.
4. The state machine shape above.
5. Hard-stop on the "skill catches itself cheating" class of errors — **no soft-fail**.
6. Slack integration deferred to Phase B; placeholders go in now.
7. Auto-verify deferred to Phase C; `blocked-verify` escapes to `blocked-user` in the interim.
8. **Platform adapter**: auto-detect from `git remote get-url origin` per repo. GitHub → `gh`, GitLab → `glab`, anything else → blocked-user.
9. **Per-item `repo:` label resolution**: for each item (single ticket, list item, or sub-task), at most one `repo:<name>` label is resolved to a subdirectory of cwd. Zero labels falls back to the cwd git repo (blocked-user only when cwd is not inside a git repo). Multiple labels are blocked. No config file, no auto-inference from title/paths.
10. **Skill-commit marker is HTML-comment-primary, trailer-fallback.** Commits always write the `<!-- ship-issue:commit -->` HTML marker; the `Co-Authored-By: Claude` trailer is added by default but dropped when any reachable `CLAUDE.md` mentions `Co-Authored-By`. Phase 3's lookup checks the HTML marker first and falls back to the trailer for historical commits made before this scheme landed.
11. **Cron-entry match via captured `<command-name>` + permissive regex fallback.** Phase 0.5's self-arm check reads the slash-command name Claude Code injects at invocation time (e.g. `/abc:ship-issue`) and uses it verbatim in both the cron arming string and the subsequent match check. A permissive regex (`(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue`) is the fallback for environments where `<command-name>` isn't reachable. This fixes a real-world correctness bug where hardcoding `/ship-issue` failed to match plugin-namespaced cron entries and caused every wake to duplicate-arm.
12. **Rebase against base is attempt-and-gate; mechanical failures escalate to `blocked-user`, not `failed`.** Prior versions had a single hard-stop: any non-trivial rebase failure → `failed: rebase-conflict-needs-human`. That was too brittle for parallel epic runs where most conflicts are textual (parallel workers add imports to the same file, JSX elements to the same component, etc.) and resolvable by git's three-way merge. New rule: attempt `git rebase origin/<base>`, then run the project's local gates, and only escalate on (a) conflict markers (`blocked-user: rebase-needs-human`) or (b) red gates after a clean rebase (`blocked-user: rebase-clean-but-tests-failed`). Semantic shift: `failed` is reserved for self-cheating and hard correctness walls; mechanical rebase trouble is **recoverable by re-running `/abc:ship-issue <same-arg>` (or `/abc:ship-issue-gh <same-arg>`) after resolving** — not by the cron staying armed. **CronDelete fires on ALL halts** (blocked-user, failed, all-merged): a `blocked-user` halt cancels the loop just like the terminal states, so re-running the command after the human resolves the conflict is what re-arms it. The self-cheating hard stop still applies *inside* the auto-resolve flow — a clean rebase that only goes green by deleting an assertion is the cheat, not the fix. The legacy `rebase-conflict-needs-human` reason string is removed.

## Open questions for the implementation ticket

These are implementation choices, not architecture:

1. ~~**Cancellation mechanism.**~~ **Resolved:** a standalone `cancel` Linear comment (case-insensitive, whole-comment-body or first line) is scanned in Phase 3 and derives `failed: cancel-requested` → CronDelete. `/loop cancel` stays as the manual override.
2. **Linear status updates.** Does the skill write status transitions, or just read? Recommendation: write on `implementing`, `pr-open`, `merged` so there's an audit trail. Verify which status updates don't trigger unwanted Linear notifications.
3. **PR ↔ Linear linking.** Use Linear's Magic URL format in the PR description so the issue auto-transitions? (Likely yes — free audit trail.)
4. **Sub-issue discovery.** Which Linear MCP call returns a parent's sub-issues in order? Smoke-test in A.2.
5. **Session notes.** In-memory only, or a local scratch file? Recommendation: in-memory; if debugging needs persistence, use Linear comments (durable, shareable) rather than local files.
6. **Stacked PRs.** PROJ-83..86 required stacking on top of each other's branches. Does ship-issue auto-stack when it detects a common file touch-point, or does it serialise (wait for merge before starting the next)? Serialise is simpler for v1.

## Review checklist (for the architect-role reviewer)

Per the AI-native workflow principle *the ability to criticise AI will be more valuable than the ability to produce code*, this doc needs a human signing off on:

- [ ] State machine captures real-world situations — any state missing?
- [ ] Blocked triggers are neither too loose (skill halts constantly) nor too tight (skill silently makes bad calls).
- [ ] Escape hatches cover the "AI cheats to pass" failure mode explicitly. **This is the most important one.**
- [ ] Session-boundary behavior is truly stateless — no hidden assumption about local files surviving.
- [ ] What-the-skill-does-not-do list doesn't miss anything we'd regret later.

After sign-off, the implementation ticket picks up with implementation against these decisions.
