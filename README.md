# ABC — Always Be Cooking

A personal workflow toolkit for Claude Code: a tight, opinionated set of slash commands and subagents that take a feature from **idea → plan → Linear issues → parallel shipping → review → merge** with the fewest possible re-explanations.

> "Always Be Cooking" — the mindset of staying in motion. The toolkit encodes the recurring loops so the human only does the parts that require judgment.

---

## The lifecycle

```
   /abc:plan                       →  PLAN-<slug>.md (draft, fast, ship-aware)
        ↓
   /abc:scaffold-sub-issues        →  Linear parent + sub-issues + dependency graph
   /abc:scaffold-sub-issues-gh     →  GitHub parent + children (task-list + label DAG)
        ↓
   /abc:ship-epic | ship-epic-gh   →  parallel multi-repo shipping (fans out workers)
        OR
   /abc:ship-issue | ship-issue-gh →  serial single-ticket worker (the unit)
        ↓
   /abc:review-sweep               →  bulk-triage your open PRs/MRs across GitHub + GitLab
        ↓
                                     merged

   Off-pipeline utilities:
     /abc:pr      — local change → PR (GitHub) or MR (GitLab)
     /abc:review  — review a single PR/MR with craft-level attention
```

Each step in the pipeline produces an artifact the next step consumes. No state lives in shell history or chat memory — **the tracker (Linear or GitHub Issues) and the git remote are the source of truth**, so any step can resume across sessions, machines, or days.

Pick the family by tracker: the unsuffixed skills target Linear; the `-gh` siblings target GitHub Issues. `plan`, `pr`, `review`, and `review-sweep` are tracker-agnostic and shared by both.

---

## Skills

| Command | What it does |
|---|---|
| `/abc:plan <description>` | Drafts a `PLAN-<slug>.md` within 3-5 tool calls. Sub-tasks are structured for `/abc:scaffold-sub-issues` to consume — each has a `repo:` tag, scope, acceptance criteria, and optional `blocks`/`blocked by` dependencies. Writes the file fast and lets you iterate from disk, not from Q&A. |
| `/abc:scaffold-sub-issues [parent-id] [plan-paths]` | Reads one or more PLAN-*.md files, proposes a Linear parent + sub-issues with repo labels and dependency edges, asks for confirmation, then creates them. Output is a parent ID you can paste into `/abc:ship-epic`. |
| `/abc:scaffold-sub-issues-gh [<owner>/<repo>[#<n>]] [plan-paths]` | GitHub-Issues sibling. Same input shape and confirmation gate, but creates a GitHub parent issue with a managed `## Sub-issues` task-list plus `status:*` / `repo:*` / `blocks:*` labels (emulating Linear's state machine and relations on top of GitHub). Output is a parent `<owner>/<repo>#<n>` ID. See `plugins/abc/skills/scaffold-sub-issues-gh/github-conventions.md` for the label scheme shared across the `-gh` family. |
| `/abc:ship-issue <TICKET\|list\|parent\|milestone:uuid>` | Drives a Linear issue (or list / parent / milestone) from Backlog to Done through the implement → PR → address-review → merge loop. Self-arms its own `/loop` — invoke once and walk away. |
| `/abc:ship-issue-gh <<owner>/<repo>#<n>\|list\|parent\|milestone:<owner>/<repo>/<num>>` | GitHub-Issues sibling. Same self-arming loop, same state machine + escape hatches, but drives GitHub issues using the label/task-list conventions from `scaffold-sub-issues-gh/github-conventions.md`. GitHub-only — GitLab repos go through `/abc:ship-issue` instead. |
| `/abc:ship-epic <PARENT-ID>` | Coordinator for parent issues with multi-repo sub-issues. Builds a dependency graph from `blocks`/`blocked by` relations, fires `/loop /abc:ship-issue <SUB-ID>` per ready sub-issue (truly parallel via independent cron entries), gates blocked sub-issues, aggregates status to the parent. See `plugins/abc/skills/ship-epic/DESIGN.md` for the architectural rationale. |
| `/abc:ship-epic-gh <<owner>/<repo>#<n>>` | GitHub-Issues sibling. Coordinator for a GitHub parent issue with a managed `## Sub-issues` task-list. Builds the dependency graph from `blocks:#N` / `blocked-by:#N` labels on the children, fires `/loop /abc:ship-issue-gh <owner>/<repo>#<n>` per ready child, gates blocked children, aggregates status. Single-host (github.com OR Enterprise) per invocation. |
| `/abc:pr [title-hint]` | Local change → PR/MR. Inspects the diff, groups related files, runs type-check + tests, commits with no AI attribution, pauses for confirmation, opens the PR/MR. Detects GitHub vs GitLab automatically. |
| `/abc:review <url\|number>` | Review a single PR or MR with craft-level attention: semantic HTML, CSS architecture (tokens, logical properties, `light-dark()`), accessibility, TypeScript patterns, code quality. Proposes inline comments, shows them for approval, posts only what you confirm. Auto-detects platform from URL or git remote. |
| `/abc:review-sweep [github\|gitlab\|both]` | Scans your open PRs/MRs across platforms, dispatches each unresolved reviewer comment to the `triage` subagent, presents a dashboard, and applies confirmed fixes per PR/MR. Designed to compose with `/loop 30m /abc:review-sweep` for unattended sweeps. |

---

## Subagents

Both are tightly scoped, read-only by contract, and used by the orchestrating skills above. They are not invoked directly.

| Agent | Used by | What it does |
|---|---|---|
| `reviewer` | `/abc:review`, `/abc:review-sweep` | Analytical code reviewer. Reads a diff (plus repo-rule overrides at `.claude/review-rules.md`) and returns structured inline comment proposals with severity, category, and concrete suggestion blocks. Volume-scales depth: small diffs get nits, large diffs get errors/security/a11y only. No write tools. |
| `triage` | `/abc:review-sweep` | Single-comment classifier. Given one reviewer comment + its diff context, returns a YAML block with classification (`fixable-code` / `fixable-doc` / `question` / `judgment-required` / `noise`), confidence, rationale, and (for fixable items) a proposed suggestion block. Tight contract — no investigation, no implementation. |

---

## Hooks

Background helpers that fire on Claude Code lifecycle events. No direct invocation — they activate automatically when the plugin is installed.

| Hook | When it fires | What it does |
|---|---|---|
| `stay-awake` | `UserPromptSubmit` / `Stop` / `Notification` (idle) / `SessionEnd` / `PostToolUseFailure` (on interrupt) | Prevents macOS from sleeping during active Claude Code sessions. Critical for the autonomous-loop pattern: `/abc:ship-issue` and `/abc:ship-epic` self-arm a `/loop` that fires every 6 minutes and can run for hours — without sleep prevention, the loop dies when the screen sleeps or the lid closes. Uses `caffeinate -w $PPID` so the process auto-exits when Claude Code itself exits. macOS only — gracefully no-ops on other platforms. |

Optional environment variables:

- `CLAUDE_ABC_AWAKE_FLAGS` — flags passed to `caffeinate` (default: `-i -m -s` — prevents idle/disk/system sleep)
- `CLAUDE_ABC_AWAKE_ON_ACTIVATE` — shell command to run when stay-awake activates (e.g. a desktop notification)
- `CLAUDE_ABC_AWAKE_ON_DEACTIVATE` — shell command to run when stay-awake deactivates

---

## Design principles

- **Linear is the source of truth.** Skills are stateless across sessions; they re-derive state from Linear comments, PR/MR status, and `CronList` on every wake.
- **Pause for confirmation before destructive or visible operations.** Opening PRs/MRs, creating Linear issues, posting reviewer comments — all gated.
- **No AI attribution.** Commits, PR/MR descriptions, and Linear comments never include "Generated with Claude Code" footers or `Co-Authored-By: Claude` trailers.
- **Tool scoping at the skill level.** Each skill declares the minimum tools it needs. `/abc:review` cannot push code; `/abc:plan` cannot create Linear issues; etc.
- **Self-arming loops.** `/abc:ship-issue` and `/abc:ship-epic` arm their own `/loop` so you invoke once and walk away. They self-cancel on terminal states.
- **Compose with `/loop`.** One-shot skills like `/abc:review-sweep` can be wrapped: `/loop 30m /abc:review-sweep` keeps your queue swept while you work elsewhere.

---

## Requirements

Install only what's needed for the skills you'll actually use — every dependency is per-skill and the rest of the toolkit will still work without it.

### Claude Code

- Claude Code with plugin / marketplace support.

### Trackers (MCPs)

| Skill | Required |
|---|---|
| `/abc:scaffold-sub-issues`, `/abc:ship-issue`, `/abc:ship-epic` | Linear MCP (`claude_ai_Linear`) connected and authed |
| `/abc:scaffold-sub-issues-gh`, `/abc:ship-issue-gh`, `/abc:ship-epic-gh` | `gh` CLI (>= 2.40) authed for the target host. No Linear required. |
| `/abc:review`, `/abc:review-sweep` (GitLab paths only) | GitLab MCP (`mcp__gitlab__*`) |
| `/abc:plan`, `/abc:pr`, `/abc:review` (GitHub paths) | None — local files + `gh` CLI |

### Platform CLIs

| CLI | Used by | Auth check |
|---|---|---|
| `git` | every repo-touching skill | — |
| `gh` | GitHub repos — PR ops, comments, check runs | `gh auth status` |
| `glab` | GitLab repos — MR ops, pipelines, notes | `glab auth status` |

### Node toolchain

Used by `/abc:pr` and `/abc:ship-issue` to run typecheck/lint/tests before opening a PR/MR.

- `node`
- One of `pnpm` / `npm` / `yarn` — auto-detected from the lockfile in cwd.

### `stay-awake` hook (optional, macOS-only)

- `jq`
- `caffeinate` (ships with macOS)

The hook gracefully no-ops if either is missing or you're on a non-macOS platform.

---

## Install (local development)

```bash
# 1. Clone the repo somewhere on your machine
git clone https://github.com/semanticpixel/abc.git

# 2. Add the marketplace (point at wherever you cloned it)
claude plugin marketplace add ./abc

# 3. Install the plugin
claude plugin install abc@abc

# 4. Restart Claude Code
```

You should now see `/abc:*` commands in the slash menu.

### Updating after edits

```bash
# 1. Bump version in both manifests:
#    .claude-plugin/marketplace.json
#    plugins/abc/.claude-plugin/plugin.json

# 2. Update the installed copy
claude plugin update abc@abc

# 3. Restart Claude Code
```

### Useful commands

```bash
claude plugin list                    # see installed plugins + status
claude plugin details abc             # component inventory + token cost
claude plugin validate <path>         # check manifest validity
claude plugin disable abc@abc         # turn off without uninstalling
claude plugin uninstall abc@abc       # remove
```

---

## Install (from GitHub)

```bash
claude plugin marketplace add semanticpixel/abc
claude plugin install abc@abc
```

---

## Repo layout

```
abc/                                  ← marketplace root
├── README.md                         ← this file
├── .claude-plugin/marketplace.json   ← marketplace manifest
├── examples/                         ← sample artifacts (see below)
│   └── PLAN-avatar-component.md
├── scripts/
│   └── validate-plugin.py            ← manifest + frontmatter validator
├── .github/workflows/
│   └── validate.yml                  ← runs the validator on push / PR
└── plugins/
    └── abc/                          ← plugin root
        ├── .claude-plugin/plugin.json
        ├── skills/
        │   ├── pr/SKILL.md
        │   ├── review/SKILL.md
        │   ├── review-sweep/SKILL.md
        │   ├── plan/SKILL.md
        │   ├── scaffold-sub-issues/SKILL.md
        │   ├── scaffold-sub-issues-gh/
        │   │   ├── SKILL.md
        │   │   └── github-conventions.md
        │   ├── ship-issue/
        │   │   ├── SKILL.md
        │   │   ├── DESIGN.md
        │   │   └── README.md
        │   ├── ship-issue-gh/
        │   │   ├── SKILL.md
        │   │   ├── DESIGN.md
        │   │   └── README.md
        │   ├── ship-epic/
        │   │   ├── SKILL.md
        │   │   └── DESIGN.md
        │   └── ship-epic-gh/
        │       ├── SKILL.md
        │       └── DESIGN.md
        ├── agents/
        │   ├── reviewer.md
        │   └── triage.md
        └── hooks/
            ├── hooks.json
            └── stay-awake.sh
```

---

## Examples

| File | Shows |
|---|---|
| [`examples/PLAN-avatar-component.md`](./examples/PLAN-avatar-component.md) | A canonical multi-repo PLAN — the exact format `/abc:plan` emits and `/abc:scaffold-sub-issues` consumes. Three sub-tasks across two repos, a dependency graph, a `## Validation` block that becomes the `blocked-verify` gate in `/abc:ship-issue`. |

---

## Versioning

[Semver](https://semver.org/) with a personal-tools bias toward MINOR bumps for skill additions, PATCH for bug fixes and prompt tightening, MAJOR only when the lifecycle contract itself changes (e.g. a renamed/removed skill that breaks downstream pointers).

Per-version notes live in [`CHANGELOG.md`](./CHANGELOG.md).

---

## Author

Luis Torres
