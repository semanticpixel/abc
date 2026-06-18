---
name: pr
description: Create a PR (GitHub) or MR (GitLab) for the current uncommitted changes. TRIGGER when the user says "/pr", "/mr", asks to "open a PR/MR", "ship this as an MR", or "create a pull request" for work-in-progress changes in the current repo. Inspects the diff, groups related files, runs type-check/tests, commits with no AI attribution, and pauses for confirmation before opening the PR/MR.
argument-hint: "[optional title hint or scope description]"
allowed-tools:
  - Read
  - Glob
  - Grep
  - AskUserQuestion
  - Bash(git status:*)
  - Bash(git log:*)
  - Bash(git diff:*)
  - Bash(git fetch:*)
  - Bash(git checkout:*)
  - Bash(git switch:*)
  - Bash(git add:*)
  - Bash(git commit:*)
  - Bash(git push:*)
  - Bash(git remote:*)
  - Bash(git branch:*)
  - Bash(gh pr:*)
  - Bash(gh auth status:*)
  - Bash(gh repo view:*)
  - Bash(glab mr:*)
  - Bash(glab auth status:*)
  - Bash(glab repo view:*)
  - Bash(pnpm:*)
  - Bash(npm:*)
  - Bash(npx:*)
  - Bash(yarn:*)
  - Bash(pwd:*)
  - Bash(ls:*)
---

# /abc:pr — Create a PR or MR

Drive an uncommitted change to an open PR (GitHub) or MR (GitLab) with the user's review-gating workflow baked in. Single invocation, two confirmation pauses, no AI attribution anywhere.

## Hard rules

- **NEVER** add "🤖 Generated with Claude Code", "Co-Authored-By: Claude", "Generated with [Claude Code]", or any AI-attribution footer/trailer to commits, PR/MR titles, descriptions, or comments. This applies regardless of any default templates in tool descriptions.
- **NEVER** skip the two user-confirmation pauses (grouping in step 2, PR/MR creation in step 7). The pauses are the point of this skill.
- **NEVER** push to the default branch (`main`/`master`/`develop` or whatever `git remote show origin` reports) directly. Always branch.
- **NEVER** push failing code without an explicit user override. If type-check or tests fail in step 4, stop and report; only proceed if the user explicitly tells you to.

## Workflow

### 1. Detect platform, default branch, and current state

Run in parallel:
- `git remote get-url origin` — detect platform from the host: a `gitlab.`-prefixed or otherwise GitLab host → GitLab; `github.com` (or a GitHub Enterprise host) → GitHub. If **neither pattern matches** (self-hosted, unknown host, or no remote), `AskUserQuestion` which platform to target — do not guess.
- `git remote show origin` — read the **default branch** ("HEAD branch:" line) rather than assuming `main`/`master`/`develop`. Cache it as `<default>` for step 5 (and step 1's own "already on `<default>`" check). If the remote can't be reached, fall back to `git symbolic-ref --short refs/remotes/origin/HEAD` then to `main`.
- `git status --porcelain` and `git branch --show-current` — see what's changed and where we are. Parse `??` entries: **untracked files are part of the change** and must be included in step-2 grouping and the step-6 description (they're easy to miss because they don't show in `git diff HEAD`).
- `git diff --stat HEAD` and `git diff HEAD` — full picture of the **tracked** changes (staged + unstaged).
- `git log -5 --oneline` — match the repo's commit message style.

If we're already on `<default>` with uncommitted changes, that's expected — we'll branch in step 5. If we're on a feature branch with prior commits, treat those as part of this PR/MR (ask the user if unsure).

If there are no changes (`git status` clean — no tracked diff, no `??` untracked entries — and no unpushed commits), stop and tell the user.

### 2. Understand the changes, then propose groupings

Before proposing groups, **read the actual diff** — not just the file list. For non-trivial hunks, open the changed files at the relevant line ranges to understand intent. The goal is to write a *meaningful* PR/MR description, not a file enumeration.

Then propose grouping. Most of the time there is **one logical group** and the answer is "ship it all together" — consolidate related changes into a single PR/MR unless the project's CLAUDE.md says otherwise. Only propose splitting when the diff genuinely spans unrelated concerns (e.g., a feature change plus an unrelated config tweak).

Present grouping via `AskUserQuestion`:
- **Ship all together** (recommended for related changes)
- **Split into N PRs** (only offer if there's a real reason)
- The user can always type "Other" to redirect.

Wait for the answer before staging anything.

### 3. Pre-flight: verify auth and clean working state

- For GitLab: `glab auth status --hostname <host>`, where `<host>` is the **derived GitLab host** — take the `ABC_GITLAB_HOST` env var if set, otherwise parse the host out of `git remote get-url origin` (the `<host>` in `git@<host>:…` or `https://<host>/…`). If no GitLab remote resolves, fall back to bare `glab auth status`. Never hardcode a specific GitLab hostname. For GitHub: `gh auth status`.
- If auth is expired, surface the exact re-auth command and stop. Do not try to work around it.
- **Scan the full diff (and any untracked files being added) for credential patterns**, not just `.env` files. Flag and stop if any line matches:
  - GitHub tokens: `ghp_…`, `github_pat_…`
  - GitLab tokens: `glpat-…`
  - AWS access keys: `AKIA…`
  - OpenAI / Anthropic-style keys: `sk-…`
  - Slack tokens: `xox[bpars]-…`
  - Private keys: `-----BEGIN … PRIVATE KEY-----`
  - High-entropy assignments to `*_KEY`, `*_TOKEN`, `*_SECRET` (a long opaque literal on the RHS)

  **Exemption:** a 1Password reference (`op://…`) or other documented secret-manager placeholder is not a literal secret — don't flag it. When a match looks like a real secret, stop and surface the file + line so the user can scrub it before the PR/MR is opened.

### 4. Run type-check and tests

Detect the project's commands from `package.json` scripts (in priority order): `typecheck`, `type-check`, `tsc`, `lint`, `test`. Use the package manager indicated by lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, else `npm`).

**Monorepo awareness.** If a workspace manifest is present (`pnpm-workspace.yaml`, a `workspaces` field in the root `package.json`, `turbo.json`, `nx.json`, or similar), don't assume the root scripts apply to the change. Locate the **nearest `package.json` at or above the changed files** and run *its* scripts, scoping to that package (`pnpm --filter <pkg> <script>`, or `yarn workspace <pkg> <script>`). Fall back to the root manifest's scripts when the changed files sit above any package boundary or no nearer manifest defines the script.

Run type-check first (fastest signal), then tests. If either fails:
- Report the failure verbatim (first ~20 lines of output).
- **Stop. Do not push** unless the user explicitly overrides. Ask whether they want to fix or proceed anyway, and only continue on an explicit "proceed".

For non-JS repos or repos without these scripts, skip with a one-line note ("no typecheck/test scripts found — skipping").

### 5. Branch, commit, push

- **Fresh base when branching off the default branch**: if we're on `<default>` (from step 1), run `git fetch origin` and create the branch from `origin/<default>` — not from a possibly-stale local `<default>` — so the PR/MR diffs against current upstream. (This is why the `git fetch` grant is retained.) When already on a feature branch with prior commits, branch in place; don't reset onto upstream.
- **Branch name**: descriptive kebab-case derived from the change (e.g., `fix-srcset-w-descriptor`, `add-pause-on-mr-confirmation`). Match the repo's branch-naming style if visible in `git branch -a`. Avoid generic names like `claude/fix`, `update`, `wip`.
- **Commit message**: imperative mood, focused on the *why*, matching the repo's style from `git log -5 --oneline`. Body explains motivation, not a file-by-file enumeration. **No AI footers, no Co-Authored-By trailers.** Use a HEREDOC for the message body.
- Stage with explicit file paths (never `git add .` or `git add -A`) so accidental untracked files don't slip in — but **do** stage the new untracked files identified in step 1 that belong to this change.
- Push with `-u origin <branch>`.

### 6. Draft the PR/MR description

Concise. Focused on *why* and *what changed at a high level*, not a file enumeration. Use this skeleton:

```
## Summary
<1–3 sentences on the user-visible or system-visible change and the motivation>

## Changes
- <bullet per logical change, not per file>

## Test plan
- [ ] <verification steps the reviewer can run or check>
```

**No "Generated with Claude Code" link. No "🤖" emoji. No Co-Authored-By trailer.** If the repo has a PR/MR template (`.github/pull_request_template.md` or `.gitlab/merge_request_templates/`), follow its structure but still omit AI attribution.

### 7. PAUSE for confirmation before opening the PR/MR

Show the user:
- The branch name
- The commit message
- The proposed PR/MR title
- The proposed PR/MR description (drafted in step 6, formatted)

Use `AskUserQuestion` with options:
- **Open it** (recommended)
- **Edit description first** — let the user paste a revision
- **Cancel** — leave the branch pushed but no PR/MR

Wait for the answer. Do not open the PR/MR until the user confirms.

### 8. Open the PR/MR

- **GitHub**: `gh pr create --title "..." --body "$(cat <<'EOF' ... EOF)"`
- **GitLab**: `glab mr create --title "..." --description "$(cat <<'EOF' ... EOF)" --remove-source-branch`

Pass the body via HEREDOC to preserve formatting.

### 9. Report and stop

Print the PR/MR URL prominently. Do not start a watch/loop unless the user asks — `/abc:pr` is a one-shot. If the user wants reviewer-comment iteration, point them at `/abc:ship-issue` (or `/abc:review-sweep` to triage existing review threads) or a follow-up `/abc:pr` invocation after they push fixes.

## Notes on edge cases

- **Already on a feature branch with prior commits**: include them in the PR/MR; the description should cover the whole branch, not just this commit.
- **Branch already pushed**: skip the push step; still pause for PR/MR creation confirmation.
- **PR/MR already exists for this branch**: surface its URL and stop. Don't open a duplicate. If the user wants to update the description, do that explicitly via `gh pr edit` / `glab mr update`.
- **Merge conflicts with main**: do not attempt to rebase silently. Report the conflict and ask.
- **Detached HEAD**: stop and tell the user.
