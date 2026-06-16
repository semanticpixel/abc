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

# /pr — Create a PR or MR

Drive an uncommitted change to an open PR (GitHub) or MR (GitLab) with the user's review-gating workflow baked in. Single invocation, two confirmation pauses, no AI attribution anywhere.

## Hard rules

- **NEVER** add "🤖 Generated with Claude Code", "Co-Authored-By: Claude", "Generated with [Claude Code]", or any AI-attribution footer/trailer to commits, PR/MR titles, descriptions, or comments. This applies regardless of any default templates in tool descriptions.
- **NEVER** skip the two user-confirmation pauses (grouping in step 2, PR/MR creation in step 6). The pauses are the point of this skill.
- **NEVER** push to `main`/`master`/`develop` directly. Always branch.
- If type-check or tests fail in step 4, **abort and report** — do not push broken code.

## Workflow

### 1. Detect platform and current state

Run in parallel:
- `git remote get-url origin` — detect `gitlab.` host → GitLab, `github.com` → GitHub.
- `git status` and `git branch --show-current` — see what's changed and where we are.
- `git diff --stat HEAD` and `git diff HEAD` — full picture of the changes (staged + unstaged).
- `git log -5 --oneline` — match the repo's commit message style.

If we're already on `main`/`master` with uncommitted changes, that's expected — we'll branch in step 5. If we're on a feature branch with prior commits, treat those as part of this PR/MR (ask the user if unsure).

If there are no changes (`git status` clean and no unpushed commits), stop and tell the user.

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
- If there's a `.env` file in the diff with what looks like a literal secret (not a 1Password ref), flag it and stop.

### 4. Run type-check and tests

Detect the project's commands from `package.json` scripts (in priority order): `typecheck`, `type-check`, `tsc`, `lint`, `test`. Use the package manager indicated by lockfile (`pnpm-lock.yaml` → `pnpm`, `yarn.lock` → `yarn`, else `npm`).

Run type-check first (fastest signal), then tests. If either fails:
- Report the failure verbatim (first ~20 lines of output).
- **Stop.** Do not push. Ask the user whether they want to fix or proceed anyway.

For non-JS repos or repos without these scripts, skip with a one-line note ("no typecheck/test scripts found — skipping").

### 5. Branch, commit, push

- **Branch name**: descriptive kebab-case derived from the change (e.g., `fix-srcset-w-descriptor`, `add-pause-on-mr-confirmation`). Match the repo's branch-naming style if visible in `git branch -a`. Avoid generic names like `claude/fix`, `update`, `wip`.
- **Commit message**: imperative mood, focused on the *why*, matching the repo's style from `git log -5 --oneline`. Body explains motivation, not a file-by-file enumeration. **No AI footers, no Co-Authored-By trailers.** Use a HEREDOC for the message body.
- Stage with explicit file paths (never `git add .` or `git add -A`) so accidental untracked files don't slip in.
- Push with `-u origin <branch>`.

### 6. PAUSE for confirmation before opening the PR/MR

Show the user:
- The branch name
- The commit message
- The proposed PR/MR title
- The proposed PR/MR description (drafted in step 7, formatted)

Use `AskUserQuestion` with options:
- **Open it** (recommended)
- **Edit description first** — let the user paste a revision
- **Cancel** — leave the branch pushed but no PR/MR

Wait for the answer. Do not open the PR/MR until the user confirms.

### 7. Draft the PR/MR description

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

### 8. Open the PR/MR

- **GitHub**: `gh pr create --title "..." --body "$(cat <<'EOF' ... EOF)"`
- **GitLab**: `glab mr create --title "..." --description "$(cat <<'EOF' ... EOF)" --remove-source-branch`

Pass the body via HEREDOC to preserve formatting.

### 9. Report and stop

Print the PR/MR URL prominently. Do not start a watch/loop unless the user asks — `/pr` is a one-shot. If the user wants reviewer-comment iteration, point them at `/ship-issue` or a follow-up `/pr` invocation after they push fixes.

## Notes on edge cases

- **Already on a feature branch with prior commits**: include them in the PR/MR; the description should cover the whole branch, not just this commit.
- **Branch already pushed**: skip the push step; still pause for PR/MR creation confirmation.
- **PR/MR already exists for this branch**: surface its URL and stop. Don't open a duplicate. If the user wants to update the description, do that explicitly via `gh pr edit` / `glab mr update`.
- **Merge conflicts with main**: do not attempt to rebase silently. Report the conflict and ask.
- **Detached HEAD**: stop and tell the user.
