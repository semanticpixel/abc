# CLAUDE.md — abc plugin marketplace

## What this is

Personal Claude Code marketplace shipping the **abc** plugin: a tight, opinionated set of skills that automate the feature-shipping lifecycle.

**Lifecycle:** `/abc:plan` → `/abc:scaffold-sub-issues[-gh]` → `/abc:ship-issue[-gh]` or `/abc:ship-epic[-gh]` → `/abc:review-sweep` → merged.

Two parallel tracker families:

- **Linear-flavored** (no suffix): `scaffold-sub-issues`, `ship-issue`, `ship-epic` — for work projects.
- **GitHub-flavored** (`-gh` suffix): same skills against GitHub Issues — for personal projects. The label scheme, task-list fence, and marker comments shared across the `-gh` family are documented in `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md`.

The `plan`, `pr`, `review`, `review-sweep` skills are tracker-agnostic; they don't have `-gh` siblings.

## Repo layout

```
abc/
├── README.md                            ← user-facing overview
├── CLAUDE.md                            ← this file
├── examples/                            ← sample artifacts (PLAN docs etc.)
├── scripts/validate-plugin.py           ← manifest + frontmatter validator
├── .github/workflows/validate.yml       ← runs the validator on push / PR
├── .claude-plugin/marketplace.json      ← marketplace manifest
└── plugins/abc/                         ← the plugin
    ├── .claude-plugin/plugin.json       ← plugin manifest
    ├── skills/                          ← each subdir is one skill
    │   ├── plan/                        ← /abc:plan
    │   ├── scaffold-sub-issues/         ← /abc:scaffold-sub-issues (Linear)
    │   ├── scaffold-sub-issues-gh/      ← /abc:scaffold-sub-issues-gh (GitHub)
    │   ├── ship-issue/                  ← /abc:ship-issue (Linear)
    │   ├── ship-issue-gh/               ← /abc:ship-issue-gh (GitHub)
    │   ├── ship-epic/                   ← /abc:ship-epic (Linear)
    │   ├── ship-epic-gh/                ← /abc:ship-epic-gh (GitHub)
    │   ├── pr/                          ← /abc:pr (tracker-agnostic)
    │   ├── review/                      ← /abc:review
    │   └── review-sweep/                ← /abc:review-sweep
    ├── agents/                          ← reviewer + triage subagents
    └── hooks/                           ← stay-awake (macOS sleep prevention)
```

## Conventions (apply when editing this repo)

- **No AI attribution.** Commits, PRs, MRs, Linear comments, GitHub issue comments — never include "Generated with Claude Code", `Co-Authored-By: Claude`, or similar footers. (Inherited from the user's global CLAUDE.md.)
- **Confirmation before visible/destructive ops.** Opening PRs/MRs, creating Linear/GitHub issues, posting reviewer comments — always gate behind `AskUserQuestion`.
- **Tool scoping per skill.** Each `SKILL.md` declares the minimum `allowed-tools` it needs. Don't pile on permissions across skills.
- **Trackers are the source of truth.** Skills derive state freshly on each `/loop` wake from comments + the marker scheme `<!-- ship-issue:* -->` / `<!-- ship-epic:* -->`. Nothing is persisted locally.
- **`repo:<name>` label convention.** Each sub-issue carries exactly one `repo:*` label; `ship-*` skills resolve the matching `<cwd>/<name>/` subdirectory as the workdir.
- **Sequential sub-issue creation.** When creating multiple sub-issues, do them serially — the tracker's `createdAt` ordering is what walk-order skills depend on. Parallel creates can collide at sub-second precision and scramble the order.
- **Verb-noun skill names** (`ship-issue`, `review-sweep`, `scaffold-sub-issues`). Matches the abc namespace style. Avoid noun-noun names like the original `plan-breakdown` (renamed to `scaffold-sub-issues` for this reason).
- **Self-arming loops.** `/abc:ship-issue` and `/abc:ship-epic` arm their own `/loop 6m` so the user invokes once and walks away. They self-cancel via `CronDelete` on terminal states. Mirror this contract in any new long-running skill.

## Working in this repo

### Editing a skill

1. Edit `plugins/abc/skills/<skill-name>/SKILL.md` (and `DESIGN.md` / `README.md` if they exist for that skill).
2. Bump the version in **both** manifests — they must stay in sync:
   - `plugins/abc/.claude-plugin/plugin.json` → the plugin's version
   - `.claude-plugin/marketplace.json` → the plugin entry's version (NOT `metadata.version`)
3. Bump rules (**every user-visible change ships in a versioned release** — don't accumulate docs/CI under `[Unreleased]`; `claude plugin update` is a no-op when the version hasn't moved):
   - **MINOR** for new skills, new hooks, or breaking changes to a skill's contract.
   - **PATCH** for anything else a user-installer should see — prompt edits, README/CHANGELOG/CLAUDE.md changes, example files, CI tooling that affects published validation, bug fixes.
   - **MAJOR** only when the lifecycle contract itself changes (renamed/removed skill that breaks downstream pointers).
4. Update the top-level `README.md` if the skill table or lifecycle diagram changed.
5. Add a `CHANGELOG.md` entry under the new version's section in the same PR. `[Unreleased]` is a staging area only for in-flight branches — it should be empty on `main` between releases.
6. For user testing: `claude plugin update abc@abc`, then restart Claude Code. If the update appears to no-op, the install cache hasn't moved — use `claude plugin uninstall abc@abc && claude plugin install abc@abc` (see the README's *If `update` doesn't pick up your changes* note).

### Adding a new skill

1. Create `plugins/abc/skills/<verb-noun-name>/SKILL.md`. Mirror the frontmatter shape of an existing skill (e.g. `ship-issue/SKILL.md`).
2. Set `allowed-tools` to the minimum needed — don't copy `ship-issue`'s full list unless you actually need PR/MR ops.
3. Add a row in `README.md`'s Skills table.
4. Bump plugin + marketplace versions (MINOR).
5. If the skill has substantial design rationale, add `DESIGN.md` alongside `SKILL.md`. If users need an install/usage guide, add `README.md` too (only `ship-issue` has all three so far).

### Adding a hook

Hooks live at `plugins/abc/hooks/`. Pattern:

- `hooks.json` maps Claude Code lifecycle events (`UserPromptSubmit`, `Stop`, `Notification`, `PostToolUseFailure`, `SessionEnd`) to script invocations.
- Scripts use `${CLAUDE_PLUGIN_ROOT}/hooks/<name>.sh` so they resolve regardless of install location.
- `chmod +x` the script before committing.
- Scripts should gracefully no-op on missing tools — start with `command -v jq >/dev/null 2>&1 || exit 0` (and similar for any other dependency).

## Files to always read before working here

1. `README.md` — full lifecycle, skill table, install flow.
2. The specific skill's `SKILL.md` — implementation contract.
3. That skill's `DESIGN.md` if it exists — architectural rationale.
4. `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md` — shared conventions across the `-gh` family.

## Files NOT to edit lightly

- `.claude-plugin/marketplace.json`'s `metadata.version` field — that's the marketplace's own version (currently `0.1.0`), separate from the plugin's version. Touch only when the marketplace structure itself changes.
- `plugins/abc/agents/reviewer.md` and `triage.md` — subagents under a tight read-only-by-contract design. Changes here propagate to `/abc:review` and `/abc:review-sweep` behavior; review the orchestrating skills first.
- `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md` — load-bearing across all three `-gh` skills. Changes to label names, the task-list fence, or marker-comment formats break all of them simultaneously.
