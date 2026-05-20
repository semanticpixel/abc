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

### Changed

- `README.md` — added a Quickstart section near the top so a reader can install + try `/abc:plan` before scrolling through Lifecycle / Skills / Subagents / Hooks / Design / Requirements. Tagline updated to drop the Linear-specific framing now that both backends are first-class.
- Slash-menu tracker hints — every tracker-coupled `SKILL.md` description now leads with `Linear ·` or `GitHub ·` so the slash menu telegraphs which tracker is required without the user opening the file. Six skills touched (`scaffold-sub-issues`, `ship-issue`, `ship-epic` and their `-gh` siblings). The four tracker-agnostic skills (`plan`, `pr`, `review`, `review-sweep`) are intentionally unprefixed.
- `scripts/validate-plugin.py` + `.github/workflows/validate.yml` — frontmatter validation now actually parses the YAML (via PyYAML) rather than just checking the `---` fence. Catches `[…]`-at-start flow-sequence breaks, unterminated quotes, and missing required keys (`name`, `description`). The workflow installs `pyyaml` before running the validator.

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

[Unreleased]: https://github.com/semanticpixel/abc/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/semanticpixel/abc/releases/tag/v0.7.0
[0.6.0]: https://github.com/semanticpixel/abc/releases/tag/v0.6.0
[0.5.0]: https://github.com/semanticpixel/abc/releases/tag/v0.5.0
[0.4.0]: https://github.com/semanticpixel/abc/releases/tag/v0.4.0
