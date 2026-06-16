# Changelog

All notable changes to the `abc` plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Bump rules (see [CLAUDE.md § Editing a skill](./CLAUDE.md#editing-a-skill)):

- **MINOR** for new skills, new hooks, or breaking changes to a skill's contract.
- **PATCH** for prompt tightening, bug fixes, doc edits.
- **MAJOR** only when the lifecycle contract itself changes (renamed/removed skill that breaks downstream pointers).

Both manifests (`.claude-plugin/marketplace.json` and `plugins/abc/.claude-plugin/plugin.json`) must move in lockstep on every release — the CI validator catches drift on every PR.

## [Unreleased]

## [0.9.6] - 2026-06-16

### Changed

- **`review` + `review-sweep` + reviewer/triage agent-contract correctness sweep** (PATCH — ST-5 of the plugin review remediation, parent #47). Single-sources the review rulebook, makes the skill↔agent contracts true, and fixes `review-sweep`'s approval-gate and platform bugs. `review/SKILL.md` gains `Agent` in `allowed-tools`; no other tool-scope changes.
  - **Universal review rulebook single-sourced.** The full rule list lived in *both* `review/SKILL.md` and `reviewer.md` and had already drifted. `/abc:review` now dispatches the `abc:reviewer` subagent (passing the diff, full files, platform, head ref, and `.claude/review-rules.md` inline) instead of inlining the rules; the inlined copy is deleted. `reviewer.md` is now the **single** rulebook (a distinctive rule phrase greps to one file). Its orchestrator list is corrected to name the real callers — `review`, `review-epic`, `review-epic-gh` (not `review-sweep`, which only dispatches `triage`). The richer rationale/actionability from the deleted `review/SKILL.md` copies (hardcoded-color token-override guidance, "specificity bomb" for ID selectors, the token-semantic/primitive-misuse explanations) was back-ported into `reviewer.md` so the consolidation is lossless in *detail*, not just coverage.
  - **`subagent_type` namespacing.** `review-sweep` Phase 3 now dispatches `subagent_type: abc:triage` (was the bare `triage`, which doesn't resolve in a live plugin session); the Phase 3 heading no longer claims it dispatches `reviewer`.
  - **Approval-gate hard rules made real.** Hard rule #1 is rewritten with an explicit scoped exception — review-*thread* fixes always require the Phase 4→5 gate; the Phase 1.5 health pre-pass is the sole exception, limited to rebases and one-shot CI repairs. Phase 1.5b's CI-repair commit is now **staged locally** and rendered in the dashboard as `ci-fixed (staged) — ready to push — approve?`, force-pushed only on Phase 5 approval (rebases, which change no content, still push in-pass). Replying is folded into the Phase 4 gate option text (`Apply all fixable fixes and reply 'Fixed in <SHA>' to each thread`) so no posting/replying/pushing path exists without an `AskUserQuestion` option that covers it.
  - **Triage bucketing fixed.** `noise` is rendered as a collapsed `skipped (noise): N` count (was dropped); any `confidence: low` result is re-mapped to `judgment-required` before bucketing (the `triage` contract required this but nothing enforced it). The dashboard spec now covers all five triage categories. The misclassified dashboard example is corrected (hardcoded-color → `fixable-code`; a JSDoc typo is the `fixable-doc` exemplar).
  - **GitHub thread resolution is now real.** Phase 2 fetches review threads via `gh api graphql` (`reviewThreads { isResolved }`) and filters `isResolved: false`; the old "author replied 'Done'" heuristic is demoted to a secondary fallback.
  - **Workdir resolution defined once.** A single rule (remote-URL match against cwd subdirectories → known mapping → escalate) replaces the two contradictory definitions; the bogus `repo:` label mention is deleted (that convention is `ship-*`-only). No-clone behavior is dashboard-escalate in Phase 1.5 (never prompts); prompting is allowed only in user-confirmed Phase 5.
  - **Platform detection gaps closed (`review`).** Bare-number input checks the `upstream` remote before `origin` (fork workflows); a "neither pattern matched" terminal `AskUserQuestion` fallback is added.
  - **GitLab identity de-ambiguated.** `review-sweep` Phase 1 prefers an MCP-native authenticated-user call over scraping `glab auth status`, and specifies host selection when multiple hosts are authed.
  - **Agent-contract contradictions fixed.** `triage.md` drops the unsatisfiable "resolved by a later push" noise criterion (it has no commit history in its inputs) and adds an advisory-only caveat for local Grep/Read (cwd may not match the PR branch). `reviewer.md` calls its output a "YAML list" (was "JSON-like"), states all inputs arrive inline (local reads only when the orchestrator confirms a checkout), and reconciles "end with a one-line summary" against "no closing remarks". `review/SKILL.md` is retitled `# /abc:review` and its trigger phrasing uses `/abc:review`.

## [0.9.5] - 2026-06-14

### Changed

- **`review-epic` + `review-epic-gh` correctness sweep** (PATCH — ST-4 of the plugin review remediation, parent #47; SKILL prose + shared helper only, no `allowed-tools` changes). The two sibling reviewers were kept in lockstep section-by-section; fixes differ only on tracker-specific lines (Linear MCP / GitLab `glab` vs GitHub `gh`):
  - **Review now pinned to the reviewed SHA (both, multiple sites).** Phase 3 step 1 re-reads HEAD alongside the diff and aborts the pass with `[head-moved]` (no marker) when it differs from the SHA Phase 2 selected; the pinned SHA flows through the GitHub review POST's `commit_id` and the GitLab `position` (built from the `diff_refs` captured with the diff, never a fresh read), and is the exact value written in the `<!-- review-epic:reviewed-at:<sha> -->` dedup marker — so a marker can never claim a SHA the review wasn't produced against. The Linear local-read path additionally asserts `git -C <workdir> rev-parse HEAD == <reviewed-sha>` before letting the reviewer read full files from the checkout — on mismatch it aborts `[head-moved]` or falls back to `gh api ?ref=<reviewed-sha>`, closing the gap where a stale workdir checkout could feed the reviewer bytes that don't match the marker's SHA.
  - **`subagent_type: reviewer` → `subagent_type: abc:reviewer` (both).** Plugin agents register namespaced; the bare name does not resolve in a live session (smoke-tested once against `abc:reviewer`).
  - **Reviewer input contract filled out (both Phase 3 step 2).** Now passes platform + PR/MR ref, the contents of `<workdir>/.claude/review-rules.md` when present, and full files for every touched path. Working-directory handling diverges by platform: Linear states the absolute repo root in the prompt (local checkout exists); GitHub fetches full files via `gh api` for the reviewed SHA and instructs the reviewer **not** to attempt local reads (a cross-repo child may have no checkout).
  - **Gate-then-post merge race closed (both).** After `AskUserQuestion` approval and immediately before each post, the target's state is re-checked; a target merged/closed in the interim is skipped with `[merged-before-post]` and no marker.
  - **Missing post-failure guard copied into `-gh`.** A 4xx on posting now halts the pass **without** dropping the dedup marker, so the SHA is retried next tick (the Linear variant already had this).
  - **`status:done` terminal clause deleted from `-gh`.** Termination keys on `state=closed` only — the label was fiction.
  - **Zombie-loop-on-fetch-failure distinguished (both).** A permanent parent-read failure (404/410/not-found) runs Phase 5 termination + `CronDelete`; a transient one (timeout/5xx/auth) halts-and-retries, surfacing `stalled on same error; run /loop cancel` once when it repeats. `-gh` previously specified nothing here.
  - **Terminal marker scan now finds the markers (both Phase 5).** The terminal tick re-runs Phase 2 enumeration with state filters dropped (all children, `--state all`) — by termination every reviewed child PR/MR is merged/closed, so the default open-only enumeration found nothing to summarize.
  - **Phase 6 output contract completed.** `review-epic` gains example lines for the remaining Phase 0.7 skip categories (`[no-workdir]`, `[unknown-platform]`); both variants document the new `[head-moved]` and `[merged-before-post]` skip states.
  - **`_shared/compact-on-merge.md` staleness fixed.** `review-epic` is shipped, not "planned" — consumer list and the Reviewers trigger-boundary section updated.

## [0.9.4] - 2026-06-13

### Changed

- **`ship-epic` + `ship-epic-gh` coordinator correctness sweep** (PATCH — ST-3 of the plugin review remediation, parent #47; SKILL/DESIGN prose + `ship-epic` `argument-hint` only, no `allowed-tools` changes). The two sibling coordinators were kept in lockstep section-by-section; fixes differ only on tracker-specific lines (Linear MCP / relations / state names vs GitHub `gh` / labels / task-list):
  - **In-flight match never matched the coordinator's own workers.** The fire string is plugin-namespaced (`/abc:ship-issue[-gh] <id>`) but the `in-flight` classification grepped the bare `/ship-issue[-gh] <id>`, so the coordinator never recognized its own running workers and duplicate-fired every wake. The Phase 3 fire string and the Phase 2 `in-flight` match key are now defined **once** as the same namespace-aware regex (`(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-issue[-gh] <id>`, GitHub-ID boundary class on the `-gh` side) and referenced from both. The worker command is **derived** from the captured coordinator `<command-name>` (`ship-epic`→`ship-issue`, namespace preserved) — no more hardcoded `/abc:` fire strings.
  - **Phantom `event:resumed` removed.** No worker ever writes `<!-- ship-issue:event:resumed -->`. The `blocked-user` classification now keys on whether a human (non-skill) comment or a `<!-- ship-issue:verify:passed -->` marker **postdates** the latest `event:blocked` marker — if so the child is **re-fireable** (classify `ready` when blockers are satisfied); re-firing the worker is how a blocked child resumes. Documented in both SKILL.md and DESIGN.md.
  - **gh `merged` row no longer bypasses the validation gate.** `state=closed AND stateReason=completed` now additionally requires the worker's `<!-- ship-issue:event:merged -->` marker, plus `<!-- ship-issue:verify:passed -->` when the child body has a `## Validation` heading. A closed-completed child lacking the merged marker isn't classified `merged` yet (the worker may still be finishing the gate).
  - **Cycle path terminates.** A detected dependency cycle is now an explicit Phase 5 terminal — write `<!-- ship-epic:event:cycle -->` once (deduped against an identical prior marker), `CronDelete` the epic's own loop, halt. The user-mention-ambiguous halt path also gained an explicit `CronDelete`.
  - **Classification can't fall through silently.** Linear gains a manually-Done row (`statusType=completed`, no `event:merged` marker, no PR/MR → `merged`); both coordinators gain a final catch-all (`blocked-user: unclassifiable-child`). A human-canceled child (closed/canceled **without** the worker's `event:failed` marker) is now `dropped (human-canceled)` — surfaced and continued, **not** an epic-halting failure (only a real worker `event:failed` halts).
  - **Read-failure + single-session rules added (mirrors the workers).** Any failed read → skip classifying that child this wake (don't fall through to a wrong state); parent unreadable on consecutive wakes → `CronDelete` + halt. First-wake single-session constraint: a foreign `<!-- ship-epic:status -->` comment → `blocked-user: possible-duplicate-coordinator`; a live `ship-issue[-gh] <PARENT-ID>` serial-walker cron → refuse with `parent-already-serial-walked`.
  - **Kill-targeting + `external-blocker` tightened.** The failed-path worker-kill now references the namespace-aware cron-match rule, and appends a **non-marker** informational comment to each killed child (so it isn't mistaken for a worker event). `external-blocker` is one consistent state name, recorded only in the epic's status comment, never on the child.
  - **Linear-only fixes.** `milestone:` args are now **rejected** (pointed at `/abc:ship-issue milestone:<uuid>`, mirroring `-gh`); `argument-hint` drops `milestone:`; the "is milestone-mode useful?" question moved to DESIGN.md. The parent-already-Done early exit (print summary, no loop, no comment) now mirrors `-gh`. The Phase 4 status-comment example drops the undefined `ST` column to match the `-gh` example (State | Sub-issue | Latest).
  - **Stale `ship-epic/DESIGN.md` refreshed.** "Not a committed skill yet" banner replaced; the install path moved from `~/.claude/skills/` to the marketplace layout; the state table synced with the corrected SKILL.md Phase 2 (including `external-blocker`, `dropped (human-canceled)`, catch-all, manually-Done rows).
  - **Two residual Linear↔GitHub lockstep gaps closed (review follow-up).** The Linear `blocked-user` row gained the non-terminal guard the `-gh` row already had (`statusType` neither `completed` nor `canceled`) so a blocked-then-canceled child falls through to `dropped (human-canceled)` instead of stalling permanently as `blocked-user`. The Linear `merged` row's manually-Done OR-arm now **excludes** `## Validation`-gated issues (they fall through rather than skipping the verify gate — the `event:merged` arm already implies the gate ran, the manually-Done arm doesn't). Mirrored into `ship-epic/DESIGN.md` Phase 2. Also fixed a stale `ship-epic/DESIGN.md` cycle line that still read "Detect cycles → `blocked-user` on parent. Halt." — now points at the Phase 5 terminal (`event:cycle` + `CronDelete`) consistent with the rest of the sweep.

## [0.9.3] - 2026-06-13

### Changed

- **`ship-issue` + `ship-issue-gh` state-machine correctness sweep** (PATCH — ST-2 of the plugin review remediation, parent #47; body/DESIGN/README only, no frontmatter changes). The two sibling skills were kept in lockstep section-by-section; fixes differ only on tracker-specific lines (Linear MCP / state names vs GitHub `gh` / labels):
  - **Invalid CLI / search forms fixed.** `gh pr checks` now uses the supported `--json name,state,bucket` (the `--json name,state,conclusion` form it never supported), and rows 3a/3b/4 classify on `bucket` (`fail`/`pass`/`pending`/`skipping`/`cancel`); the Linear sibling's CI vocabulary is aligned to the same conceptual schema (`glab` `failed`/`success`/`running`/`pending`). The bogus `gh pr list --search "linked:<n>"` qualifier is replaced by a union of `closedByPullRequestsReferences`, a `#<n> in:body` search, and a `<n>-` head-branch match. The fictional `gh issue list --search` cursor pagination for milestone >250 expansion is replaced with `gh api "/repos/<o>/<r>/issues?...&state=all" --paginate` (filtering `.pull_request==null`).
  - **State table & escape-hatch correctness.** Added a terminal **row 0** (already-closed/canceled with no merged PR → skip in list context, `blocked-user: ticket-already-terminal` in single-ticket context, first-match-wins ahead of row 1). The failcount reset scan now reads the **latest** `failcount:<key>=N` comment per key (append-only comments made "any N>0" re-fire the reset forever). Added a stale-CI freshness guard (a failing check counts only against the current head SHA; older failures are treated as `pending`). Added behind-base detection to Phase 3 (`mergeStateStatus=BEHIND` / `glab` diverged counts) and wired it to the previously-unreachable rebase trigger.
  - **Contradictions resolved.** CronDelete now fires on **all** halts (blocked-user, failed, all-merged) — the rebase-escalation rationale is reworded to "recoverable by re-running the command after resolving," not "cron stays armed." The @-mention triple-contradiction is settled in favor of the Phase 4 `fixing` handler as canonical (actionable → act; ambiguous/redirect/cancel → `blocked-user`); Phase 6/7 defer to it. The merge policy is now explicit ("this skill NEVER runs `gh pr merge` / `glab mr merge` — a human merges") with a one-time `<!-- ship-issue:note:merge-nudge -->` after 5 merge-ready `pr-open` wakes.
  - **Validation gate hardened.** The `blocked-verify` template now includes the unlock instruction verbatim (`post a comment containing exactly <!-- ship-issue:verify:passed -->`, then re-run the command), and both READMEs document the marker. To stop the `Closes`-trailer / Linear-magic-close-word from racing the gate, `pending → implementing` step 7 uses `Refs <o>/<r>#<n>` (GitHub) / omits the magic close word (Linear) when the issue has a `## Validation` heading, so the worker drives the close after the gate passes.
  - **Per-team & ordering fixes.** Linear state names are now resolved by `statusType` (`started`/`completed`/`canceled`/`unstarted`) at Phase 1 and cached, with default-name fallback — handlers reference the resolved-state variables instead of hardcoded "In Progress"/"In Review"/"Done"/"Canceled". A standalone `cancel` comment (case-insensitive, whole-body or first line) is now scanned in Phase 3 and triggers a terminal halt + CronDelete.
  - **Reading-order & template fixes.** The escape-hatches phase is retitled **Phase 3.5: Escape hatches (run before handlers)** so execution order matches reading order (3 → 3.5 → 4); every internal "Phase 5" cross-reference was updated. The Phase 8 output contract uses a `<command-name>` placeholder in the `Next wake:` line instead of the literal command. The stale duplicated state table in `ship-issue/DESIGN.md` § Session-boundary behavior is replaced with a pointer to SKILL.md Phase 3 as the single source of truth, and `ship-issue/README.md`'s install section now uses the marketplace-install paragraph matching the GitHub sibling.

## [0.9.2] - 2026-06-12

### Changed

- **Permission-grant alignment sweep across every skill** (PATCH — ST-1 of the plugin review remediation, no behavior change beyond eliminating permission prompts that stalled unattended `/loop` wakes): a mechanical pass over all 12 `SKILL.md` frontmatters so that every command a body mandates is covered by a grant, and no grant is left unreferenced.
  - **`git -C <workdir> …` invocations now have matching grants.** `ship-issue`, `ship-issue-gh`, and `review-epic` derive the platform/branch via `git -C <workdir> remote get-url origin` (and `ship-issue[-gh]` via `git -C <workdir> log … --grep`), which the prefix grants `Bash(git remote:*)` / `Bash(git log:*)` never matched (`git -C` ≠ `git remote`). Added scoped `Bash(git -C * remote get-url *)` and `Bash(git -C * log *)` instead of a blanket `Bash(git -C:*)` (which would over-grant `git -C … push/reset`). The now-dead plain `Bash(git remote:*)` was dropped from `ship-issue` and `review-epic` (their only remote call is the `git -C` form); `ship-issue-gh` keeps it (its Phase 1 row-0 still uses plain `git remote get-url`).
  - **`co-authored-by` detection switched from an ungranted `grep` to the granted `Grep` tool** in the `ship-issue` pair.
  - **`gh --version` preflight removed** from `ship-issue-gh` and `scaffold-sub-issues-gh` (the command was never granted, and gh ≥ 2.40 dates to 2023): a failing `--json body` call is now treated as `blocked-user: gh-too-old-for-json-body` instead.
  - **Tmpfile writes replaced with stdin heredocs** (`--body-file -`) in `ship-epic-gh` and `scaffold-sub-issues-gh` — no `Write` tool is granted in those skills, so the prior `--body-file <tmpfile>` couldn't have produced the file. The heredoc form stays inside the existing `gh issue …` grants.
  - **`review-sweep` health pre-pass grants completed:** added `Bash(git rebase:*)`, `Bash(git restore:*)`, `Bash(gh run view:*)`, and the GitLab pipeline MCP tools (`list_merge_request_pipelines`, `list_pipeline_jobs`, `get_job`, `download_job_log`); the vague "use the existing MCP tools" line now names them.
  - **`review` fallback comment path** rewritten from the ungranted `gh pr comment` to the already-granted `gh api -X POST /repos/<o>/<r>/issues/<n>/comments`.
  - **`ship-epic-gh` PR discovery named explicitly** as `gh pr list --search <child-ref>` (already granted); the unreferenced `Bash(gh pr view:*)` was dropped.
  - **Dropped unreferenced grants:** `AskUserQuestion` (`ship-issue`, `ship-issue-gh`, `ship-epic`, `ship-epic-gh` — autonomous loops, never prompt); `Bash(pwd:*)`/`Bash(ls:*)` (`ship-epic`, `review-epic-gh`); `Bash(gh issue list:*)` (`review-epic-gh`); `Bash(gh issue edit:*)` (`ship-epic-gh`); `Skill`, `Bash(glab mr note:*)`, `mcp__gitlab__discussion_resolve` (`review-sweep`); `mcp__claude_ai_Linear__get_issue` (`review`); `Bash(git pull:*)`/`Bash(git stash:*)`/`Bash(node:*)` (`pr` — `git fetch` kept for ST-9); `mcp__claude_ai_Linear__list_users` (`scaffold-sub-issues`); `Bash(gh api:*)` (`scaffold-sub-issues-gh`); `Bash(git log:*)` (`plan`).
  - **`ship-issue/README.md` permissions JSON re-synced** with the new `git -C` grants and the previously-missing `mcp__claude_ai_Linear__list_milestones`.

## [0.9.1] - 2026-06-06

### Changed

- **`review-epic` + `review-epic-gh` post gate re-worded to match stateless reality** (PATCH — wording fix, not a behavior change): the Hard Rule previously claimed one `AskUserQuestion` approval "covers all subsequent posts for the life of the loop" while also stating no consent is persisted — impossible under the per-tick stateless model. Both skills now document the gate as **per-tick**: the first review pass of each tick that has a review to post asks once, approval covers that tick's posts, no-op ticks never ask, and a pending review blocks its tick until a human answers (walk-away *between* reviews, not *during* them). The unattended-posting alternative was considered and explicitly deferred. Carried from the PR #44 review follow-up.
- **`review-epic-gh` Phase 2 gains the branch→PR resolution mitigations from `review-epic`** (cross-cut carried from the PR #45 review): on **0 matches** (custom branch name + no `Closes` trailer), fall back to the child issue's timeline cross-references before declaring `[no-pr-yet]`; on **2+ matches**, take the first open PR and flag the ambiguity in the tick output.
- **README documents the two-session epic pattern as a first-class workflow**: new section with the terminal-pair diagram, the 5-step scaffold → two sessions → ship/review → clean-exit shape, the anti-pattern callout (never run reviewer + workers in one session), the per-tick post-gate trade-off, and an explicit **spec-mapped, not yet runtime-validated** status note for the review-epic pair's multi-repo routing and GitLab posting paths. Lifecycle diagram and repo-layout tree updated (`_shared/`, `review-epic/`, `review-epic-gh/` were missing); CLAUDE.md lifecycle line updated.
- **`review-epic-gh` Phase 2 timeline fallback narrowed to strong implements-signals** (PR #46 review): the bare `cross-referenced` fallback could pick an unrelated PR that merely mentions the child and burn the dedup marker on it. Now prefers `connected` Development-panel links, then `cross-referenced` PRs whose head branch contains the child number; mention-only PRs are deliberately excluded as `[no-pr-yet]` rather than risking a wrong-PR review.
- **Per-tick gate concurrency documented** in both `review-epic` Hard Rules (PR #46 review): a blocked `AskUserQuestion` holds the single-session turn, so an interim cron fire neither spawns a concurrent reviewer nor races the dedup marker — "walk away during a gate" is non-destructive but stalling, and there is never more than one in-flight review per session.

## [0.9.0] - 2026-06-06

### Added

- **`/abc:review-epic` — new skill** (MINOR): Linear sibling of `/abc:review-epic-gh`, completing the review-epic pair. Same review-only contract — self-arming `/loop 12m`, ≤30KB epic-context bootstrap with the dedup-against-parent rule, `abc:reviewer` subagent with cross-cutting context, one-time `AskUserQuestion` post gate, structured summary (inline index / spec cross-reference by sub-issue ID / forward-looking flags), compact-between-reviews boundary, termination within one tick of the parent reaching Done. The delta is plumbing: parent + sub-issues resolved via Linear MCP (`get_issue` / `list_issues` with `parentId` — native sub-issues replace the `-gh` task-list fence), per-child platform routing via the `repo:` label → workdir → `git remote` convention from `ship-issue` Phase 1 (GitHub PRs via `gh`, GitLab MRs via `glab`, including the positioned-discussion posting path for GitLab inline comments), and branch resolution from Linear's `gitBranchName`. Children that fail repo routing are skipped-with-a-line, not loop-halting — review-only skills degrade by narrowing coverage. No Linear write tools granted: markers live on the PR/MR, never the Linear issue.
- **`review-epic/linear-conventions.md`** — the Linear↔GitHub data-model mapping table (fence → `parentId`, labels → native relations, derived branch → `gitBranchName`) plus the marker-placement rule that makes the `<!-- review-epic:reviewed-at:<sha> -->` dedup namespace shared and platform-agnostic across both review-epic variants.

### Changed

- **README skills table** gains the `/abc:review-epic` row; CLAUDE.md repo layout updated.

## [0.8.0] - 2026-06-06

### Added

- **`/abc:review-epic-gh` — new skill** (MINOR): review-only counterpart to `/abc:ship-epic-gh` and the second session of the two-session epic-shipping pattern validated during the carn v0.1.0 delivery. Self-arming `/loop 12m` against a GitHub parent issue with a managed `## Sub-issues` task-list. Per tick: bootstraps ≤30KB of epic context (parent body verbatim, per-child acceptance criteria + dependency labels, merged-sibling diffstats + prior summary comments, pending children's criteria with a documented trim order), enumerates open child PRs not yet reviewed at their current HEAD SHA via `<!-- review-epic:reviewed-at:<sha> -->` marker-only comments (unchanged PRs cost exactly one dedup check), spawns the existing `abc:reviewer` subagent with the cross-cutting context appended to its prompt (agents/reviewer.md untouched), and posts one review per PR: inline comments plus a summary structured as (a) inline index, (b) spec cross-reference citing acceptance bullets by sub-issue ID, (c) forward-looking flags naming the pending child. Terminates within one tick of the parent closing (summary + `CronDelete`). Hard rules: never merges/pushes/closes/labels; never edits the parent fence; anti-pattern callout against running it in the same session as the shipping skills.
- **`review-epic-gh/github-conventions.md`** — thin re-export pointing at the canonical `scaffold-sub-issues-gh/github-conventions.md`, plus the one marker namespace this skill owns.

### Changed

- **`_shared/compact-on-merge.md`** gains the third consumer class: **reviewers**, at the "between two PR reviews" boundary — prompt then end the tick when un-reviewed targets remain (dedup markers persist, next tick resumes exactly there), with the reviewer-variant prompt format. Consumers list updated; `review-epic` (Linear) remains the planned sibling.
- **README skills table** gains the `/abc:review-epic-gh` row; CLAUDE.md repo layout updated.

## [0.7.12] - 2026-06-05

### Added

- **`_shared/compact-on-merge.md` — new shared helper** documenting the compact-on-merge convention: trigger Claude Code conversation compaction at the natural terminal boundary of a shipped sub-issue (worker: inside the `merged` handler after the tracker writes, before advancing to the next queued item; coordinator: end of a wake that observed ≥1 child newly reach `merged`, derived statelessly from the prior `<!-- ship-epic:status -->` snapshot). Documents **what persists** (everything load-bearing lives in the tracker / cron / git — the post-compaction wake is identical to a fresh-session resume, which the skills already support) and the **mechanism decision**: researched fallback chain is (1) direct SDK `compact()` call — not available; (2) skill-runtime sentinel the harness interprets — not available (`PreCompact`/`PostCompact` hooks react to compaction, they can't trigger it); (3) documented user-action prompt (`🗜 Sub-issue <ref> merged. Run /compact now …`) — **ships as v1**, with the harness's built-in auto-compaction as the backstop and (1)/(2) recorded as the one-file upgrade path.
- **`--no-compact` flag** on all four shipping skills (`ship-issue`, `ship-issue-gh`, `ship-epic`, `ship-epic-gh`): stripped from `$ARGUMENTS` before shape detection, retained in the raw arg string so the cron entry carries the opt-out across wakes (nothing is persisted locally), and propagated by coordinators to every worker they fire.

### Changed

- **`ship-issue` / `ship-issue-gh` `merged` handlers** gain a compact-on-merge step (after the terminal comment): print the compaction prompt as the last output of the wake when a non-terminal item remains, then **end the wake** — the next `/loop` wake picks up `<next-ref>` fresh post-compaction. Same-wake continuation would surface the prompt only after the next item's work accumulated, too late to free anything.
- **`ship-epic` / `ship-epic-gh` Phase 4** gains a "Compact-on-merge (end of wake)" step: print the coordinator-variant prompt after the terminal block when ≥1 child newly merged this wake (vs. the prior `<!-- ship-epic:status -->` snapshot), with a **first-wake baseline guard** — no prior snapshot ⇒ the current merged set is the baseline, no prompt (prevents spurious prompts when resuming an epic with already-merged children). Skipped on no-op and terminal wakes.
- **README skills table** rows for the four `ship-*` skills show the `[--no-compact]` flag, plus a note under the table pointing at the shared helper.

## [0.7.11] - 2026-05-23

### Added

- **`ship-issue-gh/DESIGN.md` — new "Known design tensions" section** capturing the `Closes`-trailer / `blocked-verify`-handler race observed during `/abc:ship-issue-gh semanticpixel/theluistorres#21` (PR #33, May 2026). On a PR carrying both a `Closes <owner>/<repo>#<n>` trailer and a linked issue with a `## Validation` heading, GitHub's auto-close fires on merge *before* the worker's next wake — so by the time Phase 3 row 1a derives `blocked-verify` and posts the validation steps, the issue is already closed and any dashboard treats it as Done. The validation gate runs as a post-mortem instead of a gating signal. Recommended manual workaround: omit the `Closes` trailer on cutover-style PRs whose linked issue has a `## Validation` heading; let the worker call `gh issue close --reason completed` itself in the `merged` handler after observing `<!-- ship-issue:verify:passed -->`. A new "Open questions" entry tracks the skill-level fix (auto-omit on heading detection) as a candidate next step, deferred unless the manual workaround proves error-prone.

## [0.7.10] - 2026-05-23

### Added

- **`.github/workflows/release.yml` — automated tag-and-release on version bump.** Triggers on push to `main` and detects whether `plugins/abc/.claude-plugin/plugin.json`'s `version` changed against the previous commit (`github.event.before`). When bumped, extracts the matching `## [<version>] - <date>` section from `CHANGELOG.md` verbatim, creates the matching `v<version>` annotated tag at the merge SHA, and calls `gh release create` with the extracted notes. `--latest` is set only when the new version is strictly higher than every existing release tag (semver-sorted via `sort -V`) so a hypothetical 0.6.x backport landing after 0.7.x can't steal the Latest pin. `pull_request` triggers run the same detection in dry-run mode, logging the would-create tag and the rendered notes to the Checks tab without writing anything — gives every release PR a smoke test before merge. A `workflow_dispatch` trigger lets a human re-run the release detection on demand (compares HEAD against its parent); tag and release creation are guarded by existence checks so re-runs on the same commit are idempotent — useful when a tag fails to publish on the first try due to a transient `gh` outage. Permissions scoped to `contents: write` only.

## [0.7.9] - 2026-05-23

### Added

- **`/abc:review-sweep` Phase 1.5b — CI repair (production-code-only, one attempt).** Extends Phase 1.5 with a CI-repair step that runs **after** the rebase pre-pass (from 0.7.8) for PRs/MRs that came out health-OK. Fetches failing checks via the GitHub Checks/Status APIs (GitLab equivalent via MCP), classifies each as `assertion-style` (typecheck / test / lint / build) or `non-assertion` (env / secrets / deps / infra). Non-assertion failures escalate immediately. Assertion failures get **one** attempt at an auto-fix — bounded by a **test-path guardrail** (heuristic globs `**/*.test.*`, `**/*.spec.*`, `**/__tests__/**`, `**/test/**`, `**/tests/**`) that rejects any proposed fix touching a test file and escalates as `proposed fix would modify test file (production-only auto-fix); needs your judgment`. Successful fixes commit with the standard `<!-- ship-issue:commit -->` marker (so any future `/abc:ship-issue[-gh]` wake on this PR finds the commit correctly), `git push --force-with-lease`, post a marker-only `<!-- review-sweep:health:ci-fixed -->` comment, and continue to Phase 2. Failed gates after the patch → `git restore .` to revert, surface as `CI repair attempted but gates failed`. Self-cheating hard stop applies inside this flow.

### Changed

- **`/abc:review-sweep` hard rules** updated to mention CI repair in the push-allowance bullet (alongside the rebase pre-pass from 0.7.8) and add a new bullet codifying the production-code-only guarantee: CI repair never silently rewrites a test even when the test is the file that needs updating; the legitimate-test-update case goes to user judgment via the dashboard.
- **`/abc:review-sweep` dashboard (Phase 4)** gets three new escalation lines (`CI red (non-assertion)`, `proposed fix would modify test file`, `CI repair attempted but gates failed`) and a `ci-fixed` success line; the summary totals now include `auto-ci-fixed` alongside `auto-rebased` and `health-escalations`.
- **`/abc:review-sweep` edge-case note** *"CI is red on the PR/MR: still triage and apply fixes"* is replaced by a pointer to Phase 1.5b's behavior.

## [0.7.8] - 2026-05-23

### Added

- **`/abc:review-sweep` Phase 1.5 — PR/MR health pre-pass (attempt auto-rebase).** Runs once per enumerated PR/MR, between Phase 1 (enumerate) and Phase 2 (fetch threads). For PRs/MRs that are behind `main`/`master` and have a resolvable local workdir, the sweep now attempts `git rebase origin/<base>`, runs the project's local gates (`pnpm typecheck && pnpm test` or repo equivalent), and `git push --force-with-lease` if everything is green — posting a `<!-- review-sweep:health:rebased -->` marker on the PR/MR. Escalates with distinct dashboard lines on conflict markers (`needs manual rebase: <files>`), red gates after a clean rebase (`rebased clean but gates failed: <summary>`), or missing local workdir (`no local clone available — rebase manually`). Skips Phase 2+ for any PR/MR that escalates. Most parallel-work conflicts are textual — multiple PRs adding imports to the same file, JSX elements to the same component, lines to the same array — and resolvable by git's three-way merge. The pre-pass tries the mechanical resolution before the dashboard renders.

### Changed

- **`/abc:review-sweep` hard rules** add an explicit allowance for Phase 1.5 to push to source branches under the same self-cheating-hard-stop rule that applies to fix application (no `--no-verify`, no test deletions, no assertion widening — even when the only way to make the rebased branch pass gates is to weaken a check).
- **`/abc:review-sweep` dashboard (Phase 4)** now renders a `health:` line per PR/MR so successful auto-rebases and escalations are distinguishable at a glance. The summary line totals `auto-rebased` and `health-escalations` alongside the triage classifications.
- **`/abc:review-sweep` edge-case note** "PR/MR with merge conflicts against main: skip" is replaced by a pointer to Phase 1.5's behavior (auto-rebase attempt; escalate if non-trivial).

## [0.7.7] - 2026-05-23

### Changed

- **Rebase against base is now attempt-and-gate, not "trivial only or `failed`"** in both `ship-issue` and `ship-issue-gh`. When the branch is detected as behind `main`/`master`, the worker now runs `git rebase origin/<base>`, then the project's local gates (`pnpm typecheck && pnpm test` or repo equivalent), and only escalates on (a) conflict markers (`blocked-user: rebase-needs-human`) or (b) red gates after a clean rebase (`blocked-user: rebase-clean-but-tests-failed`). The old behavior — fail-fast on anything beyond trivial textual drift — was too brittle for parallel epic runs where most conflicts are textual (parallel workers add imports to the same file, JSX elements to the same component) and resolvable by git's three-way merge. Workers used to halt the whole epic on these; now they self-heal when safe.
- **Semantic shift: `failed` is reserved for self-cheating and hard correctness walls.** Mechanical rebase trouble is now `blocked-user` (recoverable — cron stays armed, human nudges, worker continues). The legacy `failed: rebase-conflict-needs-human` reason string is removed from both skills. The self-cheating hard stop still applies *inside* the auto-resolve flow — a clean rebase that only goes green by deleting an assertion is the cheat, not the fix. Symmetric updates across `ship-issue/SKILL.md` + `ship-issue-gh/SKILL.md` + both `DESIGN.md` files (Hard stops / Soft stops sections + new locked decision #12).

## [0.7.6] - 2026-05-22

### Fixed

- **Phase 0.5 self-arm cron-entry match rule** in all four self-arming skills (`ship-issue`, `ship-issue-gh`, `ship-epic`, `ship-epic-gh`). The rule did a substring check for `/<skill-name> <raw-arg>` against `CronList` entries — but when the skill is invoked through the `abc` plugin namespace, the cron command contains `/abc:<skill-name> <raw-arg>` and the hardcoded `/<skill-name>` substring is absent (the prefix is `:`, not `/`). The match always failed, every wake duplicate-armed a new cron, and over hours `CronList` would fill with duplicates pointing at the same args. Now uses the literal `<command-name>` Claude Code injects at invocation time (which surfaces even on `/loop`-triggered wakes), with a permissive regex `(?:[A-Za-z][A-Za-z0-9_-]*:)?<skill-name>` as the fallback. Same fix applied symmetrically across all four skills × SKILL.md + DESIGN.md.

## [0.7.5] - 2026-05-22

### Changed

- `examples/demo-full.gif` re-encoded at slightly higher quality (~3.3MB → ~5.4MB). Still well inside the GitHub README embedding budget, with cleaner text and less compression noise above the fold.

## [0.7.4] - 2026-05-22

### Added

- Real screen-recorded hero GIF (`examples/demo-full.gif`, ~3.3MB) replacing the `vhs`-rendered one from 0.7.2 that had the font-fallback letter-spacing bug. Shows a live Claude Code session moving through `/abc:plan` → `/abc:scaffold-sub-issues-gh` → `/abc:ship-epic-gh` end-to-end, ending on *"10 of 10 merged · parent closed · cron self-cancelled."*

### Changed

- README hero — embed restored at the top, now pointing at `examples/demo-full.gif`. Caption rewritten to lead with the GIF and refer the reader to the screenshot strip below for live-issue verification. The "watching for longer than 30s?" link to a separate long-arc GIF is gone — there's one canonical demo now.

### Removed

- `examples/demo.gif` — the short synthetic `vhs` GIF. The single recorded session covers both elevator-pitch and full-arc, so a separate short version is no longer needed. `demo.tape`, `demo-full.tape`, and `scripts/play-demo*.sh` stay in the repo as the scripted alternative path for anyone who wants to fork the synthetic approach.

## [0.7.3] - 2026-05-21

### Changed

- `README.md` hero — the `vhs`-rendered `examples/demo.gif` is temporarily commented out. The `ttyd` terminal it spawns couldn't resolve `JetBrains Mono` and fell back to a font that renders with per-character tracking, making the output near-unreadable. A real screen-recording is being produced as the replacement; the embed is preserved in an HTML comment so it's a one-line restore once the file is swapped. The three screenshots below the hero now stand on their own with a rewritten caption that doesn't reference the missing GIF.

### Kept

- `examples/demo.gif`, `examples/demo-full.gif`, `demo.tape`, `demo-full.tape`, and `scripts/play-demo*.sh` remain in the repo. They're cheap to keep and useful as a regenerable scripted alternative once the font-resolution path inside `ttyd` is sorted out — or as a reference for anyone who wants to fork the synthetic-output approach.

## [0.7.2] - 2026-05-21

### Added

- README hero: a `vhs`-rendered GIF (`examples/demo.gif`, ~30s) showing the `/abc:plan → /abc:scaffold-sub-issues-gh` arc from a long-form `PLAN.md` to a 10-issue GitHub epic with 15 dependency edges. Paired with a longer companion (`examples/demo-full.gif`, ~60s) that continues through `/abc:ship-epic-gh`'s worker fan-out and ends on *"10 of 10 merged · parent closed · cron self-cancelled."*
- Synthetic-output scripts (`scripts/play-demo.sh`, `scripts/play-demo-full.sh`) and paired `vhs` tape configs (`demo.tape`, `demo-full.tape`) — the GIFs are regenerable from disk with `vhs demo.tape` / `vhs demo-full.tape`, no live API or tracker auth needed.
- Real-artifact screenshots in `examples/screenshots/` linking through to [`semanticpixel/theluistorres#11`](https://github.com/semanticpixel/theluistorres/issues/11) (the parent issue), a child showing the `repo:` / `status:` / `blocks:` / `blocked-by:` label scheme, and the repo's Issues tab. The visuals prove the workflow ran end-to-end on a real repo, not just in a demo.

## [0.7.1] - 2026-05-20

This release exists to batch the docs / CI / polish that landed on top of 0.7.0 (PRs #8–#11) into a real PATCH bump, so installers see them via `claude plugin update`. See the new bump-rules note in `CLAUDE.md`: every user-visible change now ships in a versioned release, even docs and CI.

### Added

- `README.md` Quickstart — install + try `/abc:plan` before scrolling past Lifecycle / Skills / Subagents / Hooks / Design / Requirements. Tagline updated to drop the Linear-specific framing now that both tracker backends are first-class. (#8)
- Slash-menu tracker hints — every tracker-coupled `SKILL.md` description now leads with `Linear ·` or `GitHub ·` so the slash menu telegraphs which tracker is required without the user opening the file. The four tracker-agnostic skills (`plan`, `pr`, `review`, `review-sweep`) are intentionally unprefixed. (#9)
- YAML-parse step in `scripts/validate-plugin.py` + `.github/workflows/validate.yml` — frontmatter validation now actually parses the YAML (via PyYAML), not just checks the `---` fence. Catches `[…]`-at-start flow-sequence breaks, unterminated quotes, and missing required keys. (#10)
- README "If a plugin update doesn't appear" note explaining that `claude plugin update` is a no-op when the version hasn't bumped, and pointing at `claude plugin uninstall && claude plugin install` as the reliable refresh.

### Changed

- `CLAUDE.md` bump rules tightened — every user-visible change ships in a versioned release. PATCH for any change a user-installer should see (docs, CI tooling that affects published validation, examples, prompt edits). The `[Unreleased]` CHANGELOG section is now only for in-flight branches; merged PRs always ship under a version header.

## [0.7.0] - 2026-05-19

### Added

- `/abc:ship-epic-gh` — GitHub-Issues coordinator. Drives a GitHub parent issue with a managed `## Sub-issues` task-list to all-merged by firing `/loop 6m /abc:ship-issue-gh <ref>` per ready child. Builds the dependency graph from `blocks:#N` / `blocked-by:#N` labels on the children (cross-repo via `<owner>/<repo>#N` form). Same coordinator contract as `/abc:ship-epic`: 10-minute cadence, do-not-halt on `blocked-user`, halt-on-`failed` with `CronDelete` of every in-flight worker. Ships `SKILL.md` + `DESIGN.md`. ([#6](https://github.com/semanticpixel/abc/pull/6))

### Removed

- `PLAN-gh.md` — the planning doc for the GitHub-Issues sibling family. All three siblings are now landed; `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md` is the canonical reference going forward. ([#6](https://github.com/semanticpixel/abc/pull/6))

### Changed

- `CLAUDE.md` — repo layout now shows all six tracker-coupled skill directories. "Currently in-flight work" section removed. `github-conventions.md` flagged in both the "always read before working here" and "don't edit lightly" lists. ([#6](https://github.com/semanticpixel/abc/pull/6))

## [0.6.0] - 2026-05-19

### Added

- `/abc:ship-issue-gh` — GitHub-Issues unit worker. Drives a single GitHub issue (or comma-list, or parent with a managed `## Sub-issues` task-list, or milestone) from `pending` to `merged`. Same Phase 0..8 contract as the Linear sibling: self-arming `/loop`, three-strikes CI counter, self-cheating hard-stop, derived-not-stored state. Differences from `/abc:ship-issue`:
  - IDs are `<owner>/<repo>#<n>` (or `#<n>` when invoked in-repo). No `#<n>` shorthand in comma-lists.
  - State machine emulated via `status:in-progress` / `status:in-review` labels + closed-by-reason.
  - Branch derivation is deterministic: `<n>-<kebab-title>`, ASCII-only, 60-char cap.
  - Three-strikes counter key is `github:<check-name>` (GitHub-only skill).
  - Durable state via GitHub issue comments using the same `<!-- ship-issue:* -->` marker family.
- Ships `SKILL.md` + `DESIGN.md` + `README.md` — full doc set matching the Linear sibling. ([#5](https://github.com/semanticpixel/abc/pull/5))

## [0.5.0] - 2026-05-19

### Added

- `/abc:scaffold-sub-issues-gh` — GitHub-Issues sibling of `/abc:scaffold-sub-issues`. Reads one or more `PLAN-*.md` files and creates a GitHub parent issue (or appends children to an existing one) with the managed `## Sub-issues` task-list, `status:*` / `repo:*` / `blocks:*` / `blocked-by:*` labels, optional `## Validation` gate. No Linear MCP required — `gh` CLI only. ([#4](https://github.com/semanticpixel/abc/pull/4))
- `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md` — load-bearing shared reference for the entire `-gh` family. Documents the label scheme, task-list fence (`<!-- ship-epic:sub-issues:start/end -->`), marker comments, and argument forms. ([#4](https://github.com/semanticpixel/abc/pull/4))

## [0.4.0] - 2026-05-19

Initial public release. Establishes the marketplace structure and the seven Linear-flavored / tracker-agnostic skills, two subagents, and the `stay-awake` hook. Prior version history lived in a private workspace and is not reflected here.

### Added

- **Marketplace + plugin manifests**: `./.claude-plugin/marketplace.json`, `./plugins/abc/.claude-plugin/plugin.json`.
- **Lifecycle skills** (Linear-flavored): `/abc:plan`, `/abc:scaffold-sub-issues`, `/abc:ship-issue`, `/abc:ship-epic`. `ship-issue` ships `SKILL.md` + `DESIGN.md` + `README.md`; `ship-epic` ships `SKILL.md` + `DESIGN.md`.
- **Off-pipeline utilities** (tracker-agnostic): `/abc:pr`, `/abc:review`, `/abc:review-sweep`.
- **Subagents**: `reviewer` (analytical code review with structured comment proposals; volume-scales depth by diff size), `triage` (single-comment classifier with tight YAML output contract).
- **Hooks**: `stay-awake` — macOS `caffeinate -w $PPID` wrapper for long-running autonomous loops. Auto-exits when Claude Code exits; gracefully no-ops on non-macOS platforms or when `jq`/`caffeinate` are missing.
- **Top-level docs**: `README.md`, `CLAUDE.md`, `LICENSE` (MIT), `.gitignore`.

### Added (post-0.4.0, no version bump)

These landed on top of the initial 0.4.0 release without bumping — they're docs / examples / CI rather than new skills:

- README Requirements section. ([#1](https://github.com/semanticpixel/abc/pull/1))
- `scripts/validate-plugin.py` + `.github/workflows/validate.yml` — manifest + skill/agent frontmatter validation on every push and PR. Catches JSON drift, version mismatch between `marketplace.json` and `plugin.json`, missing YAML frontmatter, hook executable bit loss. ([#2](https://github.com/semanticpixel/abc/pull/2))
- `examples/PLAN-avatar-component.md` — canonical multi-repo sample PLAN. The exact format `/abc:plan` emits and `/abc:scaffold-sub-issues` consumes. ([#3](https://github.com/semanticpixel/abc/pull/3))

[Unreleased]: https://github.com/semanticpixel/abc/compare/v0.7.5...HEAD
[0.9.6]: https://github.com/semanticpixel/abc/compare/v0.9.5...v0.9.6
[0.9.5]: https://github.com/semanticpixel/abc/compare/v0.9.4...v0.9.5
[0.9.4]: https://github.com/semanticpixel/abc/compare/v0.9.3...v0.9.4
[0.9.3]: https://github.com/semanticpixel/abc/compare/v0.9.2...v0.9.3
[0.9.2]: https://github.com/semanticpixel/abc/compare/v0.9.1...v0.9.2
[0.7.5]: https://github.com/semanticpixel/abc/releases/tag/v0.7.5
[0.7.4]: https://github.com/semanticpixel/abc/releases/tag/v0.7.4
[0.7.3]: https://github.com/semanticpixel/abc/releases/tag/v0.7.3
[0.7.2]: https://github.com/semanticpixel/abc/releases/tag/v0.7.2
[0.7.1]: https://github.com/semanticpixel/abc/releases/tag/v0.7.1
[0.7.0]: https://github.com/semanticpixel/abc/releases/tag/v0.7.0
[0.6.0]: https://github.com/semanticpixel/abc/releases/tag/v0.6.0
[0.5.0]: https://github.com/semanticpixel/abc/releases/tag/v0.5.0
[0.4.0]: https://github.com/semanticpixel/abc/releases/tag/v0.4.0
