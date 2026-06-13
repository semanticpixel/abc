# ship-issue-gh

Drives a GitHub issue (or an ordered list of issues, or a parent issue with a managed `## Sub-issues` task-list) from `pending` through the implement → open-PR → address-review → merge loop. GitHub-only. Stateless — GitHub Issues + the PR's check runs are the sources of truth.

> Companion docs:
>
> - [DESIGN.md](./DESIGN.md) — architecture, state machine, locked decisions specific to the GitHub-Issues case
> - [SKILL.md](./SKILL.md) — operational procedure (what the skill executes)
> - [github-conventions.md](../scaffold-sub-issues-gh/github-conventions.md) — label scheme + marker comments shared across the `-gh` family

This is the GitHub-Issues sibling of [`/abc:ship-issue`](../ship-issue/README.md) (Linear). The two are deliberately parallel skills — pick by tracker, not auto-detect.

## What it does

- Resolves each input issue to a working directory:
  - If the issue has a `repo:<name>` label → `<name>` is matched to a subdirectory of the invocation cwd.
  - Otherwise → cwd's git repo if its remote matches the issue's `<owner>/<repo>`.
- For each issue, derives current state from GitHub Issues + the linked PR (no local persistence). Resumes rather than resets.
- Implements the issue, runs local checks, opens a PR with a `Closes <owner>/<repo>#<n>` trailer, and transitions the issue through `status:in-progress` → `status:in-review` → closed-as-completed.
- Self-arms a `/loop` at 6-minute cadence on first invocation (idempotent via `CronList`). On each wake, polls the PR. On reviewer comments — human or automated code-review bot — classifies them and either pushes a fix commit (replying on the thread with the fix SHA) or escalates to the user.
- Halts on: all-merged, `blocked-user`, or `failed` (hard error).

## Installation

This skill ships as part of the `abc` plugin marketplace — see the [top-level README](../../../../../README.md) for marketplace installation. Once the plugin is installed, `/ship-issue-gh` is available alongside the Linear sibling.

## Prerequisites

### Required CLI tools

| CLI | Required for | Auth check |
|-----|--------------|------------|
| `gh` (>= 2.40) | every operation | `gh auth status --hostname <host>` |
| `git` | every operation | — |

`gh` version 2.40 or newer is required for reliable `--json body` support on `gh issue view`. The skill version-checks on its first wake and blocks if older.

### Issue conventions

To drive an issue into a specific repo (when invoking from a parent cwd containing multiple repos), tag it with a `repo:<name>` label where `<name>` matches the target subdirectory.

To use the parent + task-list pattern, the parent issue's body must contain a managed task-list section:

```markdown
## Sub-issues
<!-- ship-epic:sub-issues:start -->
- [ ] #42 — Add WidgetRow component
- [ ] otherorg/consumer-app#7 — Adopt v2 tokens
<!-- ship-epic:sub-issues:end -->
```

`scaffold-sub-issues-gh` creates this structure automatically — see [its conventions doc](../scaffold-sub-issues-gh/github-conventions.md).

### Labels

The skill expects (and creates on demand) two `status:*` labels and may create per-edge `blocks:#<N>` / `blocked-by:#<N>` labels referenced by `/abc:ship-epic-gh`. See the conventions doc for the full scheme.

## Usage

```
/ship-issue-gh <arg>
```

Where `<arg>` is one of:

- `<owner>/<repo>#<n>` — a single issue (fully qualified).
- `#<n>` — a single issue, where `<owner>/<repo>` is inferred from `git remote get-url origin` (must be inside the target repo's working copy).
- `<owner>/<repo>#<n>,<owner>/<repo>#<m>` — comma-separated ordered list. Each entry must be fully qualified.
- `<owner>/<repo>#<parent>` where the issue's body has a managed `## Sub-issues` task-list — the skill walks the children in body order.
- `milestone:<owner>/<repo>/<num-or-name>` — expands to non-terminal issues in that milestone, ordered by `createdAt` ascending.

The skill self-arms its own `/loop` on first invocation (6-minute cadence) — you invoke once and walk away. On each wake it checks `CronList`; if no loop for this arg is armed yet, it arms one and proceeds with the work. Subsequent wakes are idempotent no-ops for the arm step.

On terminal state (all items merged, any item blocked or failed), the skill calls `CronDelete` on its own loop entry.

The skill is idempotent — re-invocations re-derive state from GitHub.

## Examples

### 1 — single issue, in-repo invocation

```
cd <workspace>/my-app
/ship-issue-gh #42
```

What happens:

- `#42` resolves to `<owner>/my-app#42` via `git remote get-url origin`.
- Skill creates branch `42-<kebab-title>`, implements against the issue body's acceptance criteria, opens a PR with `Closes <owner>/my-app#42`.
- Every 6 minutes, polls the PR and addresses reviewer comments.

### 2 — single issue, parent-cwd invocation

```
cd <workspace>
ls
# my-app/   design-system/   ...

/ship-issue-gh <owner>/design-system#15
```

What happens:

- Skill resolves `<owner>/design-system#15` to `./design-system/` (via the repo name in the ID; explicit `repo:` label is optional here since the ID is sufficient).
- Implements, opens PR, polls.

### 3 — parent issue spanning multiple repos

```
cd <workspace>
/ship-issue-gh <owner>/design-system#100
```

If `#100` is a parent with a managed task-list:

```markdown
## Sub-issues
<!-- ship-epic:sub-issues:start -->
- [ ] <owner>/design-system#101 — Add Avatar primitive
- [ ] <owner>/web-app#7 — Wire Avatar into header
<!-- ship-epic:sub-issues:end -->
```

The skill expands to `[<owner>/design-system#101, <owner>/web-app#7]` in body order. Each child gets its own `status:in-progress` → `status:in-review` → closed cycle, serialised.

> For parallel (rather than serial) shipping of independent children, use `/abc:ship-epic-gh` instead — it fans out workers per ready child via independent cron entries.

### 4 — milestone

```
/ship-issue-gh milestone:<owner>/web-app/3
```

Expands milestone #3 in `<owner>/web-app` to its non-terminal issues, ordered by `createdAt` ascending, and walks them as a list.

## Output

- **On GitHub Issues**: label transitions (`status:in-progress` → `status:in-review`), skill-authored comments marked with `<!-- ship-issue:<category>:<key>=<value> -->`, and `gh issue close --reason completed` on success.
- **On GitHub PRs**: the PR itself, with a `Closes <owner>/<repo>#<n>` trailer for auto-close, plus thread replies (`Fixed in abc1234.`) on review comments the skill addressed.
- **In the terminal**: a short per-wake summary showing each item's derived state and the currently-working item.

## Limitations

- **GitHub-only.** GitLab repos go through `/abc:ship-issue` (Linear) instead.
- **UI verification is out of scope.** If an issue body has a `## Validation` section, the skill transitions to `blocked-user` post-merge (state: `blocked-verify`) and inlines the validation text. The issue stays open until a human confirms. To clear the gate, **post an issue comment containing exactly `<!-- ship-issue:verify:passed -->`** (the unlock marker), then re-run `/ship-issue-gh <arg>` — the next wake sees the marker and advances to `merged`. On validation-gated issues the skill opens the PR with `Refs <owner>/<repo>#<n>` (not `Closes ...`), so GitHub's auto-close doesn't fire before the gate runs. Auto-verification is planned for Phase C (`/verify-ticket`).
- **The skill never merges.** It drives the PR to green-and-reviewed and waits — a human runs the merge. After the PR has been merge-ready for ~30 min (5 consecutive `pr-open` wakes) the skill posts a one-time `<!-- ship-issue:note:merge-nudge -->` comment, then keeps waiting.
- **Slack ping on blocked-user is not implemented yet.** Today the surface is a GitHub issue comment + the terminal output.
- **Repo inference is by label or by ID.** The skill does not guess the target repo from the issue title or file paths.
- **Sub-issues run serially.** Use `/abc:ship-epic-gh` for parallel coordination of independent children.
- **No `gh issue develop` integration in v1.** The branch is derived locally as `<n>-<kebab-title>`. The `Closes` trailer handles the linking; richer GitHub UI integration is a future iteration.

## Escape hatches

Same posture as the Linear sibling — conservative about two failure modes:

- **CI flakiness masking a real bug.** Three consecutive failures of the *same* named check halts with `failed`. Counter is persisted as `<!-- ship-issue:failcount:github:<check-name>=N -->` comments on the issue.
- **Self-cheating.** If the skill catches itself about to bypass a failing check — `--no-verify`, deleting an assertion, widening a type to suppress an error, `.skip()` on a failing test — it hard-stops to `failed`. No soft-retry.

## Permissions

This skill needs the standard set of git + `gh` permissions. If you're tightening `.claude/settings.local.json` to skip per-call prompts, the allowlist entries match the skill's `allowed-tools` frontmatter. See the [Linear sibling's README](../ship-issue/README.md#permissions) for the rationale on subcommand-family allowlisting — the trade-offs are identical here.

## Files

| File | Purpose |
|------|---------|
| `DESIGN.md` | Architecture + locked decisions specific to the GitHub case — read this first for behavior changes |
| `SKILL.md` | Skill definition + step-by-step operational procedure |
| `README.md` | This file |
| `../scaffold-sub-issues-gh/github-conventions.md` | Shared label scheme + marker comments + task-list fence |
