# ship-issue

Drives a Linear issue (or an ordered list of issues, or a parent with sub-issues) from **Backlog** to **Done** through the implement → open-PR → address-review → merge loop. Platform-agnostic: GitHub repos via `gh`, GitLab repos via `glab`. Stateless — Linear, GitHub, and GitLab are the sources of truth.

> Companion docs:
>
> - [DESIGN.md](./DESIGN.md) — architecture, state machine, locked decisions
> - [SKILL.md](./SKILL.md) — operational procedure (what the skill executes)

## What It Does

- Resolves each input ticket to a working directory and git platform:
  - If the ticket has a `repo:<name>` Linear label → `<name>` is matched to a subdirectory of the invocation cwd.
  - Otherwise → the cwd's own git repo is used.
  - Platform is detected from `git remote get-url origin` (GitHub → `gh`, GitLab → `glab`).
- For each ticket, derives current state from Linear + the git host (no local persistence). Resumes rather than resets.
- Implements the ticket, runs local checks, opens a PR/MR with a Linear Magic URL reference, and transitions the Linear issue through `In Progress` → `In Review` → `Done`.
- Self-arms a `/loop` at 6-minute cadence on first invocation (idempotent via `CronList`). On each wake, polls the PR. On reviewer comments — human or automated code-review bot — classifies them and either pushes a fix commit (replying on the thread with the fix SHA) or escalates to the user.
- Halts on: all-merged, `blocked-user`, or `failed` (hard error).

## Installation

This skill ships as part of the `abc` plugin marketplace — see the [top-level README](../../../../../README.md) for marketplace installation. Once the plugin is installed, `/ship-issue` is available alongside the GitHub sibling (`/ship-issue-gh`).

## Prerequisites

### Required MCPs

| MCP | Purpose |
|-----|---------|
| **Linear (`claude_ai_Linear`)** | Fetch ticket details, labels, sub-issues; write status transitions and skill-authored comments |

### Required CLI tools

| CLI | Required for | Auth check |
|-----|--------------|------------|
| `gh` | GitHub repos | `gh auth status` |
| `glab` | GitLab repos | `glab auth status --hostname <host>` |
| `git` | Every repo | — |

Install whichever you need for the platforms you'll drive. The skill blocks on `blocked-user` if the required CLI is missing or unauthed.

The GitLab `<host>` is derived per-repo (never hardcoded): the `ABC_GITLAB_HOST` env var if set, else parsed from `git remote get-url origin`, falling back to bare `glab auth status` if no GitLab remote resolves.

### Review-bot allowlist (optional)

When the skill addresses review feedback (the `fixing` state), it distinguishes **code-review-bot findings** from **human reviewer comments** by matching the comment author against an allowlist. With no config it uses a built-in default set (`dependabot[bot]`, `renovate[bot]`, `github-actions[bot]`, and common code-review bots).

To recognize additional bots — e.g. an employer-specific review bot — create `~/.claude/review-bots.md` (user-local, **not** committed to any repo):

```
# ~/.claude/review-bots.md — one bot login per line; blank lines and #-comments ignored
acme-review-bot
my-org-linter[bot]
```

Any author not in the allowlist (and not in the default set) is treated as a human reviewer. This keeps employer-specific bot names out of the published plugin.

### Linear labels

To drive a ticket into a specific repo (single-repo invocations from anywhere, or any multi-repo scenario), tag the ticket with a label `repo:<name>`:

- `<name>` must match a subdirectory of the cwd when the skill is invoked.
- Exactly one `repo:` label per ticket. Zero falls back to the cwd's git repo; two or more is a hard block.

See [DESIGN.md § Platform and repo discovery](./DESIGN.md#platform-and-repo-discovery) for the full resolution rules.

## Usage

```
/ship-issue <arg>
```

Where `<arg>` is a Linear ticket ID, a Linear URL, a comma-separated ordered list, or a parent issue.

The skill self-arms its own `/loop` on first invocation (6-minute cadence) — you invoke once and walk away. On each wake it checks `CronList`; if no loop for this arg is armed yet, it arms one and proceeds with the work. Subsequent wakes are idempotent no-ops for the arm step.

On terminal state (all items merged, any item blocked or failed), the skill calls `CronDelete` on its own loop entry, so you don't have to run `/loop cancel` manually either.

The skill is idempotent — re-invocations re-derive state from Linear + the git host.

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `<arg>` | Yes | One of: ticket ID (`PROJ-88`), Linear URL, comma-separated ordered list (`PROJ-65,PROJ-66,PROJ-67`), a parent ticket whose sub-issues will be walked in Linear order, or a project milestone (`milestone:<uuid>`) whose non-terminal issues are walked in `createdAt` ascending order |

### Examples

#### 1 — single GitHub ticket

`PROJ-88` has no `repo:` label, and you're already inside the target GitHub repo:

```
cd <workspace>/<repo-with-github-remote>
/ship-issue PROJ-88
```

What happens:

- No `repo:` label → falls back to the cwd git repo.
- `git remote get-url origin` contains `github.com` → uses `gh`.
- Implements, opens a GitHub PR, then on every 6-minute wake polls the PR and addresses code-review-bot / reviewer comments.

#### 2 — single GitLab ticket

`GRO-142` is tagged `repo:repo-b`, and your cwd has `repo-b` as a subdirectory:

```
cd <workspace>
ls repo-b
/ship-issue GRO-142
```

What happens:

- `repo:repo-b` → skill resolves to `./repo-b/`.
- `git remote get-url origin` contains `gitlab.<host>` → uses `glab`.
- Implements, opens a GitLab MR, polls the same way. Review comments get addressed and each thread gets a `Fixed in <sha>` reply.

#### 3 — parent issue with sub-tasks spanning GitHub and GitLab

`PROJ-100` is the parent. Sub-tasks, in Linear order:

- `PROJ-101` — tagged `repo:server-app` (GitLab repo)
- `PROJ-102` — tagged `repo:web-client` (GitHub repo)

The server change must merge before the client change. You invoke from the workspace that contains both:

```
cd <workspace>
ls
# server-app/   web-client/   ...

/ship-issue PROJ-100
```

What happens:

- Parent has sub-issues → skill expands to `[PROJ-101, PROJ-102]` in Linear order.
- Sub-tasks serialise. `PROJ-101` resolves to `./server-app/` on GitLab (`glab`), gets implemented and merged first.
- Only after `PROJ-101` reaches `merged` does `PROJ-102` start — it resolves to `./web-client/` on GitHub (`gh`).
- Each ticket independently gets its `In Progress` → `In Review` → `Done` transitions in Linear.

If either sub-task hits `blocked-user` (e.g. a scope-creep review comment, a merge conflict needing judgment, or a missing `repo:` label) the loop pauses with a Linear comment explaining what's needed.

#### 4 — ship every non-terminal issue in a project milestone

A milestone (e.g. "Phase 2 — Feedback Reporter") has six issues — PROJ-65 through PROJ-70 — all tagged with the same `repo:` label. You want to ship the whole phase without listing each ticket:

```
cd <workspace>/<repo-with-github-remote>
/ship-issue milestone:06826b18-9672-4ce5-b765-882f07cd6d18
```

Get the UUID from Linear's milestone URL or the milestone's info pane in the project view.

What happens:

- Skill expands the milestone to its non-terminal issues (drops anything already Done/Canceled), ordered by `createdAt` ascending — the common "created in work-order" case.
- From there it walks identically to a comma-separated list: each ticket goes through its own `implementing → pr-open → merged` cycle, in order.
- The cron is keyed on `milestone:<uuid>` so re-invocations on the same milestone are idempotent, and new tickets added to the milestone mid-flight get picked up on the next 6-minute wake.

**Caveat**: if the milestone has been manually reordered in Linear's view (dragging tickets out of creation order), the skill won't follow that manual reorder — `sortOrder` isn't exposed on issues by the MCP. Use a comma-separated list if ordering matters and creation-order isn't right.

## Output

- **On Linear**: status transitions on each ticket + skill-authored comments (marked with `<!-- ship-issue:<category>:<key>=<value> -->`) for durable state (event log, CI failure counters, verification state).
- **On GitHub/GitLab**: the PR/MR itself, with a Linear Magic URL reference in the body (`Closes PROJ-88`) so the issue auto-links.
- **In the terminal**: a short per-wake summary showing each item's derived state and the currently-working item.

## Limitations

- **UI verification is out of scope.** If a ticket description has a `## Validation` section, the skill transitions to `blocked-user` and inlines the validation text for a human to run. To clear the gate, **post a Linear comment containing exactly `<!-- ship-issue:verify:passed -->`** (the unlock marker), then re-run `/ship-issue <arg>` — the next wake sees the marker and advances to `merged`. On validation-gated tickets the skill links the PR/MR with a non-closing reference (not a magic close word), so the merge doesn't auto-complete the issue before the gate runs. Auto-verification is planned for Phase C (`/verify-ticket`).
- **The skill never merges.** It drives the PR/MR to green-and-reviewed and waits — a human runs the merge. After the PR has been merge-ready for ~30 min (measured from the last skill commit's age; the skill keeps no per-wake counter) the skill posts a one-time `<!-- ship-issue:note:merge-nudge -->` comment, then keeps waiting.
- **Slack ping on blocked-user is not implemented yet.** Today the surface is a Linear comment + the terminal output. Slack integration is planned for Phase B.
- **Repo inference is by label only.** The skill does not guess the target repo from the ticket title or file paths — a missing `repo:` label only works if the cwd is itself the right git repo. This is deliberate; see [DESIGN.md § Platform and repo discovery](./DESIGN.md#platform-and-repo-discovery).
- **Sub-tasks run serially.** If two sub-tasks touch overlapping files and could be stacked, the skill still waits for the first to merge before starting the second. v1 is serial by design (see DESIGN.md § open questions).
- **Cancellation on terminal states is automatic** (the skill calls `CronDelete` on its own loop in Phase 7). A user-initiated mid-loop cancel (e.g. a `cancel` Linear comment) is an open question in DESIGN.md; `/loop cancel` still works as the manual override.

## Escape hatches

`ship-issue` is conservative about two failure modes:

- **CI flakiness masking a real bug.** Three consecutive failures of the *same* named CI check (GitHub check-run name or GitLab pipeline job name) halts with `failed`. The counter is persisted in a Linear comment and only resets when the same check passes.
- **Self-cheating.** If the skill catches itself about to bypass a failing check — `--no-verify`, deleting an assertion, widening a type to suppress the error, `.skip()` on a failing test — it hard-stops to `failed`. No soft-retry. See [DESIGN.md § Escape hatches](./DESIGN.md#escape-hatches) for the full list.

## Permissions

Pre-approve the MCP tools and the specific Bash subcommands the skill uses by adding to your `.claude/settings.local.json`. These match the skill's `allowed-tools` frontmatter; the frontmatter gates what the model can attempt, these allowlist entries skip the per-call permission prompt.

These entries are narrowed by **subcommand family** (e.g. `git push:*`, `gh pr:*`), not by flag safety. Claude Code's permission model doesn't distinguish `git push origin main` from `git push --force origin main`; both match `Bash(git push:*)`. Likewise `Bash(git branch:*)` matches `git branch -D`. If you want to force a prompt on force-push or force-delete, drop the relevant entry from your allowlist — the skill will prompt on that call and you can approve or deny per-invocation. Destructive operations outside these subcommand families (`gh repo delete`, `glab project delete`, `rm:*`, etc.) are not pre-approved because they're not in the list.

```json
{
  "permissions": {
    "allow": [
      "mcp__claude_ai_Linear__get_issue",
      "mcp__claude_ai_Linear__list_issues",
      "mcp__claude_ai_Linear__save_issue",
      "mcp__claude_ai_Linear__list_comments",
      "mcp__claude_ai_Linear__save_comment",
      "mcp__claude_ai_Linear__list_milestones",
      "Bash(git status:*)",
      "Bash(git log:*)",
      "Bash(git diff:*)",
      "Bash(git fetch:*)",
      "Bash(git pull:*)",
      "Bash(git checkout:*)",
      "Bash(git switch:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git push:*)",
      "Bash(git branch:*)",
      "Bash(git rebase:*)",
      "Bash(git -C * remote get-url *)",
      "Bash(git -C * log *)",
      "Bash(gh pr:*)",
      "Bash(gh api:*)",
      "Bash(gh auth status:*)",
      "Bash(gh run:*)",
      "Bash(glab mr:*)",
      "Bash(glab ci:*)",
      "Bash(glab auth status:*)",
      "Bash(pnpm:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(yarn:*)",
      "Bash(node:*)",
      "Bash(ls:*)",
      "Bash(pwd:*)",
      "Bash(cd:*)"
    ]
  }
}
```

## Files

| File | Purpose |
|------|---------|
| `DESIGN.md` | Architecture + locked decisions — read this first for behavior changes |
| `SKILL.md` | Skill definition + step-by-step operational procedure |
| `README.md` | This file |
