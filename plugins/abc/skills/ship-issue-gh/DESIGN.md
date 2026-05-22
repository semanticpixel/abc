# ship-issue-gh — Design

Status: **Approved** — mirrors the Linear `ship-issue` design with GitHub-Issues-specific adaptations.

This doc exists so that humans critique the GitHub-specific deviations before any skill code is written. The state machine, three-strikes counter, self-cheating hard-stop, and self-arming `/loop` contract are all lifted **verbatim** from `../ship-issue/DESIGN.md` — read that for the universal rationale. **This file documents what changes for the GitHub-Issues case.**

**Terminology note**: this skill is GitHub-only; "PR" means GitHub pull request throughout. GitLab support lives in the Linear `ship-issue` skill.

## Purpose

Drive a GitHub issue (or list, or parent issue with a managed `## Sub-issues` task-list) from `pending` to `merged` autonomously. Invoked as `/ship-issue-gh <arg>`. Parallel sibling to `/ship-issue`, not a replacement — choose by tracker, not auto-detect.

## Why a parallel skill, not a tracker abstraction inside `ship-issue`

Locked decision from the original `-gh` family planning. Re-summarised:

- The two trackers have **different state machines, different data shapes, different durable-state primitives**. Linear has typed relations and a 5-state enum; GitHub has 2 states + label-emulation. A unified skill would carry a forked conditional through every Phase 3 row and every Phase 4 handler, which dwarfs the cost of two parallel files.
- Skill prompts are read by the model at load time. **Duplication is cheaper than abstraction** here — the model parses a focused 380-line skill more reliably than a 600-line skill with "if Linear else GitHub" branches everywhere.
- Both skills share the same `/loop` cron-arming pattern, the same three-strikes counter shape, the same self-cheating hard-stop, and the same Phase 0..8 contract. The duplication is constrained to data-access and state-mapping; the architecture is one file's worth.

## Non-goals

Same as Linear `ship-issue`:

- Writing net-new GitHub issues or breaking parents into children (that's `/abc:scaffold-sub-issues-gh`).
- Architectural decisions not scoped in the issue.
- Replacing human review.
- Auto-verifying UI changes (deferred to Phase C, `/verify-ticket`).

## Input

`<arg>` accepts:

- A single issue: `<owner>/<repo>#<n>`
- `#<n>` when invoked from inside the target repo's git working copy
- A **parent issue** whose body has a managed `## Sub-issues` task-list — children are walked in body order
- A **comma-separated list** of fully-qualified IDs in desired order
- A **milestone**: `milestone:<owner>/<repo>/<num-or-name>` — expands to non-terminal issues, ordered by `createdAt` ascending

If the arg is a parent issue without a managed task-list block, treat it as a single issue. Comma-lists must use fully-qualified IDs — `#<n>` shorthand is rejected in lists because a list can span repos and shorthand is ambiguous.

**Parent issues are the natural multi-repo pattern.** When a feature spans repos, the user creates a parent in the "hub" repo (typically the UI library or a designated planning repo) and children in each target repo, linked via the parent's `## Sub-issues` task-list. Children carry a `repo:<name>` label and the workdir is resolved per the rule below.

**Milestones are the phase-of-work pattern.** Same role as Linear milestones; the implementation uses `gh api /repos/.../milestones` to resolve the milestone, then `gh issue list --milestone <num>` to expand.

Ordering is `createdAt` ascending. Pass an explicit comma-separated list to override.

## Platform and repo discovery — GitHub-only

The Linear sibling supports both GitHub and GitLab. This skill does not — it's the GitHub-Issues track of the toolkit. GitLab support lives in `ship-issue` because Linear is the common case where a single epic spans both hosts.

### Per-item label resolution

The **same rule as the Linear sibling applies**, but with one wrinkle: an issue's `<owner>/<repo>` is *already* known from its ID, so we have a fallback even without a `repo:<name>` label.

1. Does the item have a `repo:<name>` label? → resolve `<name>` to a subdirectory of cwd.
2. No label? → look for a subdirectory of cwd matching `<repo>` (from the issue ID). Failing that, fall back to cwd itself **only if** `git remote get-url origin` matches `<owner>/<repo>`.
3. Mismatch between resolved workdir and the issue's `<owner>/<repo>`? → `blocked-user` with reason `repo-label-mismatches-workdir-remote`.

Mixing is allowed: some items in a list can have explicit `repo:` labels, others can rely on the ID-derived fallback.

### Blocked-user triggers specific to repo discovery

- Item has a `repo:<name>` label whose `<name>` doesn't match any subdirectory of cwd.
- Item has **multiple** `repo:` labels.
- Bare `#<n>` arg used outside a git repo (no way to resolve `<owner>/<repo>`).
- Origin URL host isn't a GitHub host the user is authed against (`gh auth status --hostname <host>`).

## State machine (per issue)

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

| State | Meaning | GitHub representation |
|---|---|---|
| `pending` | No work started | Open, no `status:*` label |
| `implementing` | Branch created, code in progress | Open, `status:in-progress` label |
| `pr-open` | PR open, waiting | Open, `status:in-review` label, PR linked |
| `fixing` | New reviewer comments OR failing assertion check | Open, `status:in-review` (no transient label change — `fixing` is derived from PR state, not from the issue) |
| `merged` | PR merged | Closed, `state_reason=completed` |
| `blocked-verify` | PR merged, `## Validation` exists, not yet verified | Open, `status:in-review` (issue stays open so the gate is visible) |
| `blocked-user` | Soft halt; human needed | Label preserved at whatever it was when block fired |
| `failed` | Hard stop | Closed, `state_reason=not_planned`, `status:*` labels stripped |

The shape mirrors the Linear sibling exactly — only the representation column differs.

## Durable state — GitHub specifics

The Linear sibling persists state via Linear comments with `<!-- ship-issue:* -->` markers. Same pattern here, with GitHub-specific quirks:

- Comments are fetched via `gh api /repos/.../issues/<n>/comments --paginate`, which paginates at 100/page. The `--paginate` flag handles this transparently.
- Comment **edits** are visible via `gh api .../comments/<id>` but edit history isn't reliably exposed. **Always append a new comment** rather than editing an existing one. This matches the Linear sibling's contract but the reason is different — Linear hides edit history too, but GitHub's pagination makes appended comments easier to scan.
- The well-known bot accounts for code-review automation aren't standardised — the bot identity is read from the PR comments and matched against the user's `~/.claude/review-bots.md` allowlist if present, else a default set (Renovate, Dependabot, common code-review bots). Defaulting to `noise` rather than `fixable-code` on unknown bots is safer.

## Skill-commit marker — dual-mode (HTML primary, trailer fallback)

Phase 3's "last skill commit" lookup is the load-bearing signal that distinguishes "review comments since my last push" from "all open review comments" (relevant on rows 3, 3a, 3b, 4). Earlier iterations anchored detection on a `Co-Authored-By: Claude` trailer in the commit message — convenient because git carries trailers across rebases and squashes, but this conflicts with user/repo policies that forbid AI-attribution trailers ("no AI attribution" rules are increasingly common in `CLAUDE.md`, including the user's global one and the abc-repo CLAUDE.md itself).

The skill now anchors detection on an `<!-- ship-issue:commit -->` HTML comment in the commit body. The marker:

- Is not an author attribution, so policies forbidding `Co-Authored-By: Claude` don't apply to it.
- Survives normal squash-merge (the commit body is preserved as the squashed message body) but **not** a rebase-with-fixup-squash that drops the body — that's a pre-existing limitation of any in-body marker, and matches the trailer's failure mode.
- Lives under the existing `<!-- ship-issue:* -->` marker namespace already used for durable issue-comment state, so the grep is unambiguous against other comment HTML in commit messages.

The legacy `Co-Authored-By: Claude` trailer is retained as a **fallback** in the Phase 3 lookup so historical commits (already merged or in-flight before the marker landed) continue to be detected. Phase 4 commit handlers write **both** markers by default and drop the trailer only when any reachable `CLAUDE.md` (workdir's, any ancestor walking up to `/`, or `~/.claude/CLAUDE.md`) contains a case-insensitive mention of `Co-Authored-By` — a coarse heuristic that catches "never include `Co-Authored-By`" policies without requiring prose parsing. The conservative bias is intentional: if `Co-Authored-By` is mentioned in `CLAUDE.md`, assume it's forbidden. False positives just omit a redundant trailer (the HTML marker still anchors detection); false negatives would violate a documented policy.

## Three-strikes counter — same shape, GitHub-keyed

The key format is `github:<check-name>` — the Linear sibling uses `<platform>:<check-name>` because Linear can drive both GitHub and GitLab checks, but here every check is a GitHub check-run name. Dropping the platform prefix would make migration ambiguous if the Linear sibling ever needed to read this skill's markers (it doesn't, but the cost of the prefix is one extra `github:` per comment).

The reset scan, increment-after-success-signal, and `N+1 >= 3 → failed` logic are identical to the Linear sibling. See `../ship-issue/DESIGN.md` § Phase 5.

## Branch derivation

Linear has a `gitBranchName` field on each issue — the user can customise it in the Linear UI, and the skill uses it verbatim. GitHub has no equivalent. This skill derives the branch from the issue:

```
<issue-number>-<kebab-title>
```

Where `<kebab-title>` is:

1. Lowercase the issue title.
2. Strip diacritics (NFKD normalize → drop combining marks).
3. Replace any non-`[a-z0-9]` character with `-`.
4. Collapse runs of `-` to a single `-`.
5. Trim leading/trailing `-`.
6. Truncate to 60 characters.

Example: issue #42 "Add `Avatar` primitive — initials fallback" → `42-add-avatar-primitive-initials-fallback`.

**Why not `gh issue develop`?** It can create a branch linked to the issue in GitHub's UI, but the auto-named form is undocumented and varies across `gh` versions. We pass our own deterministic name, then optionally call `gh issue develop --name <derived>` to record the link without depending on its naming. v1 skips the `gh issue develop` call entirely — the `Closes <owner>/<repo>#<n>` trailer in the PR body is enough for auto-close on merge.

## Locked decisions

Don't re-litigate without a new round of architect review:

1. **6-minute polling cadence** — same as Linear sibling.
2. **GitHub Issues + the PR's check runs are the sources of truth; skill is stateless.**
3. **GitHub-only.** GitLab support is the Linear sibling's job.
4. **State machine shape is identical to Linear sibling.** Only the representation differs.
5. **Hard-stop on self-cheating** — no soft-fail, no silent retry. The most important rule in this skill.
6. **Slack integration deferred** to Phase B (placeholders).
7. **Auto-verify deferred** to Phase C.
8. **Branch derivation is deterministic, no `gh issue develop` in v1.** Keeps the skill resilient to `gh` version drift.
9. **Comma-list args must be fully-qualified.** No `#<n>` shorthand in lists — too easy to misroute across repos.
10. **Skill-commit marker is HTML-comment-primary, trailer-fallback.** Commits always write the `<!-- ship-issue:commit -->` HTML marker; the `Co-Authored-By: Claude` trailer is added by default but dropped when any reachable `CLAUDE.md` mentions `Co-Authored-By`. Phase 3's lookup checks the HTML marker first and falls back to the trailer for historical commits made before this scheme landed.

## Open questions

These are implementation choices, not architecture:

1. **Reply-to-thread on inline review comments.** `gh api .../pulls/<pr>/comments/<comment-id>/replies` requires the comment ID. The Phase 3 fetch already retrieves comment IDs; verify they're preserved through the `fixing` handler's classification step before reaching step 5.
2. **PR vs issue commenting.** `gh pr comment <pr-num>` posts to the PR conversation; `gh issue comment <n>` posts to the issue. The marker comments (counter, event log) go on the **issue** — that's the durable timeline. PR comments are conversational with reviewers. Keep them separated.
3. **Cross-host invocations** (github.com + Enterprise host in one list). Phase 0 halts if implied. Open whether to support via `--hostname` flag in a future iteration.
4. **Issue body editing for state.** Some teams use issue body checklists for sub-task tracking. This skill never edits issue bodies — comments are the durable medium. The `## Sub-issues` task-list in parent bodies is the *one* exception, and it's managed by `scaffold-sub-issues-gh` / `ship-epic-gh`, not by this skill.
5. **Stacked PRs.** Same open question as the Linear sibling. v1 serialises.

## Review checklist (for the architect-role reviewer)

- [ ] State machine matches the Linear sibling in shape; representation column captures all GitHub-specific mappings.
- [ ] Phase 0 ID-shape disambiguation handles all the cases without ambiguity (URL, `<owner>/<repo>#<n>`, `#<n>`, comma-list, milestone, parent-with-task-list).
- [ ] The branch-derivation rule is deterministic across systems (no locale-sensitive lowercasing surprises).
- [ ] Three-strikes counter key format (`github:<check-name>`) is unambiguous against the Linear sibling's keys (which are `<platform>:<check-name>`).
- [ ] Self-cheating hard-stop list covers the GitHub-specific ergonomic shortcuts (it does — same patterns).
- [ ] Comments are append-only; no `gh api PATCH .../comments/<id>` calls in any handler.
