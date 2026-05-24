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

## [0.7.10] - 2026-05-23

### Added

- **`.github/workflows/release.yml` — automated tag-and-release on version bump.** Triggers on push to `main` and detects whether `plugins/abc/.claude-plugin/plugin.json`'s `version` changed against the previous commit (`github.event.before`). When bumped, extracts the matching `## [<version>] - <date>` section from `CHANGELOG.md` verbatim, creates the matching `v<version>` annotated tag at the merge SHA, and calls `gh release create` with the extracted notes. `--latest` is set only when the new version is strictly higher than every existing release tag (semver-sorted via `sort -V`) so a hypothetical 0.6.x backport landing after 0.7.x can't steal the Latest pin. `pull_request` triggers run the same detection in dry-run mode, logging the would-create tag and the rendered notes to the Checks tab without writing anything — gives every release PR a smoke test before merge. Permissions scoped to `contents: write` only.

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
[0.7.5]: https://github.com/semanticpixel/abc/releases/tag/v0.7.5
[0.7.4]: https://github.com/semanticpixel/abc/releases/tag/v0.7.4
[0.7.3]: https://github.com/semanticpixel/abc/releases/tag/v0.7.3
[0.7.2]: https://github.com/semanticpixel/abc/releases/tag/v0.7.2
[0.7.1]: https://github.com/semanticpixel/abc/releases/tag/v0.7.1
[0.7.0]: https://github.com/semanticpixel/abc/releases/tag/v0.7.0
[0.6.0]: https://github.com/semanticpixel/abc/releases/tag/v0.6.0
[0.5.0]: https://github.com/semanticpixel/abc/releases/tag/v0.5.0
[0.4.0]: https://github.com/semanticpixel/abc/releases/tag/v0.4.0
