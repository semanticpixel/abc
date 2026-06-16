---
name: review
description: Review a GitHub PR or GitLab MR with craft-level attention to semantic HTML, CSS architecture, accessibility, TypeScript patterns, and code quality. Auto-detects platform from URL or git remote. Proposes inline diff comments, shows them for approval, only posts what the user approves. TRIGGER when the user says "/abc:review", "review this PR/MR", "review <url>", or passes a PR/MR number.
argument-hint: "<pr-url> | <mr-url> | <number>"
model: opus
allowed-tools:
  - Agent
  - Read
  - Grep
  - Glob
  - AskUserQuestion
  - Bash(git remote:*)
  - Bash(gh pr view:*)
  - Bash(gh pr diff:*)
  - Bash(gh api:*)
  - Bash(gh auth status:*)
  - mcp__gitlab__get_merge_request
  - mcp__gitlab__list_merge_request_diffs
  - mcp__gitlab__get_repository_file_contents
  - mcp__gitlab__discussion_new_with_position
  - mcp__gitlab__discussion_new
  - mcp__gitlab__discussion_list
---

# /abc:review

Review a GitHub **pull request** or GitLab **merge request** with craft-level attention to semantic HTML, CSS architecture, accessibility, TypeScript patterns, and code quality. Auto-detects platform. Proposes inline diff comments, shows them for approval, posts only what the user approves.

**Input:** `$ARGUMENTS`

---

## Phase 0 — Detect platform and parse input

### Determine platform

Platform detection in order:

1. **URL with `github.com`** → `platform = github`
2. **URL with `gitlab.` host** (e.g. `gitlab.com`, self-hosted GitLab) → `platform = gitlab`
3. **Bare number** (e.g. `123`) → resolve the remote URL, then apply rules 1–2 against it. Check `git remote get-url upstream` **first** (fork workflows push the PR/MR to the canonical `upstream` repo, not the contributor's `origin` fork); fall back to `git remote get-url origin` if no `upstream` remote exists. If cwd is not in a git repo, or neither remote resolves → ask the user for a URL.
4. **No arguments** → ask for the PR/MR URL or number.
5. **Neither pattern matched** (an argument was passed but it's neither a recognizable URL nor a bare number, e.g. a branch name or freeform text) → terminal fallback: use `AskUserQuestion` to ask the user for the PR/MR URL or number directly. Do not guess.

Once platform is determined, verify CLI auth:
- GitHub: `gh auth status` — if not authed, surface the exact command and stop.
- GitLab: the MCP tools handle their own auth; if a call fails with auth errors, surface and stop.

### Parse identifiers

**GitHub** (`https://github.com/<owner>/<repo>/pull/<number>`):
- Extract `owner`, `repo`, `pull_number`.
- For bare-number input, derive `owner`/`repo` from the git remote.

**GitLab** (`https://gitlab.<host>/<project-path>/-/merge_requests/<iid>`):
- Extract `projectPath` (everything between the host and `/-/`), URL-decode if needed.
- Extract `mrIid`.
- For bare-number input, derive `projectPath` from the git remote.

### Load repo-specific rules

Check if `.claude/review-rules.md` exists in the current working directory:

```
Use Glob to check: .claude/review-rules.md
```

- If found, read it. These rules **augment** the universal rules below — they add repo-specific opinions on tokens, layout components, export patterns, and ignore paths.
- If not found, proceed with universal rules only. Do not warn.

---

## Phase 1 — Fetch PR/MR data

Run in parallel (per-platform):

### GitHub branch

1. **`gh pr view <number> --repo <owner>/<repo> --json title,body,author,baseRefName,headRefName,headRefOid,state,isDraft,files`** — title, description, branches, head SHA, file list.
2. **`gh pr diff <number> --repo <owner>/<repo>`** — unified diff across the PR.
3. **`gh api /repos/<owner>/<repo>/pulls/<number>/comments --paginate`** — existing inline review comments (for dedupe).

Record `headRefOid` as the commit SHA for positional comments later.

### GitLab branch

1. **`mcp__gitlab__get_merge_request`** with `projectPath` and `mrIid` — title, description, author, branches, state, draft status. Extract `diff_refs.{base_sha, head_sha, start_sha}` — needed for positional comments.
2. **`mcp__gitlab__list_merge_request_diffs`** with `projectPath` and `mrIid` — per-file unified diffs with old/new paths and line numbers.
3. **`mcp__gitlab__discussion_list`** with `projectPath` and `mrIid` — existing discussions for dedupe.

### Triage files

Classify each changed file:

| Category | Extensions / Patterns |
|----------|----------------------|
| `tsx/ts` | `.ts`, `.tsx` |
| `css` | `.css`, `.scss`, `.module.css`, `.module.scss` |
| `test` | `*.test.*`, `*.spec.*`, `__tests__/*` |
| `config` | `*.json`, `*.yaml`, `*.yml`, `*.toml`, `.eslintrc.*`, `tsconfig.*`, `*.config.*` |
| `binary` | images, fonts, `.woff2`, `.png`, `.jpg`, `.svg` (if no text diff) |
| `other` | everything else |

**Skip entirely:**
- Binary files
- Auto-generated files (check repo rules for `ignorePatterns`, plus common: `*.snap`, lockfiles, generated type files)
- Rename-only changes (old_path != new_path but no content diff)
- Deleted files (unless deletion looks accidental — e.g. a file referenced by other changed files was deleted)

### Volume scaling

Determine review depth based on size:

- **Small** (1-5 files, <200 changed lines): Thorough review — all rule categories, nits welcome.
- **Medium** (6-15 files, 200-500 changed lines): Focus on logic, CSS architecture, and accessibility. Limit nits.
- **Large** (15+ files or 500+ changed lines): Errors, bugs, security, and accessibility only. Skip nits entirely. Tell the user: "This is a large PR/MR ({N} files, {M} lines). Focusing on errors, security, and accessibility — skipping style nits."

---

## Phase 2 — Read full context

For each changed file that wasn't skipped, fetch the full file at HEAD:

- **GitHub**: `gh api /repos/<owner>/<repo>/contents/<path>?ref=<headRefOid>` and base64-decode the `content` field. (Or `gh api` with `Accept: application/vnd.github.raw` to get raw contents directly.)
- **GitLab**: `mcp__gitlab__get_repository_file_contents` with `projectPath`, file path, and `head_sha` as ref.

Also fetch **related context files** to understand usage:

- `.tsx` file changed → also read its `.module.css` / `.module.scss` (same directory, same base name)
- `.module.css` changed → also read the `.tsx` that imports it
- Component file changed → check if a corresponding `.test.tsx` / `.spec.tsx` exists

**Important:** Only generate comments on **new or changed lines** in the diff. The full files are for understanding context, not for reviewing unchanged code.

---

## Phase 3 — Analyze & generate comments

Dispatch the **`abc:reviewer`** subagent (the `Agent` tool with `subagent_type: abc:reviewer`) — it owns the universal review rulebook, volume scaling, comment tone, the actionable-comments-only rule, and the suggestion-block format. This skill does **not** inline those rules; `reviewer.md` is the single source of truth for them.

Pass everything the reviewer needs **inline in the prompt** (the agent has no platform access — it cannot fetch anything itself):

- The unified diff (per-file hunks with line numbers) from Phase 1.
- The full files at HEAD gathered in Phase 2, for context.
- The platform (`github` / `gitlab`) and the PR/MR identifier — context only.
- The head ref/SHA (`headRefOid` for GitHub, `head_sha` for GitLab) so line anchoring is unambiguous.
- The contents of `.claude/review-rules.md` if it was found in Phase 0 (repo-specific overrides that **augment** the universal rules).

The subagent returns a structured YAML list of proposed comments, one per issue on a new/changed line, each carrying:

- **severity**: `error` | `warning` | `nit` | `question`
- **category**: `a11y` | `css` | `typescript` | `test` | `quality` | `security`
- **file**: the new path of the file
- **line**: the line number in the new file (additions/modifications) or old file (deletions)
- **side**: `new` (added/modified lines) or `old` (removed lines)
- **body**: the comment text (with a `suggestion` block when there's a concrete fix)

(The exact output contract lives in the `reviewer` agent definition — match it when parsing the result for Phases 4–5.)

### Deduplicate

Before finalizing comments, check existing inline comments/discussions from Phase 1. If an existing comment already covers the same file + line + issue, skip it. At the end, note: "Skipped N comments that overlap with existing discussions."

---

## Phase 4 — Present for approval

Display all proposed comments in a numbered list:

```
## Review: {title}
**{N} comments** across {M} files ({X} errors, {Y} warnings, {Z} nits, {W} questions)

---

### 1. [error] `src/components/Card.tsx:42` — a11y
Non-interactive `<div>` has an `onClick` handler. Use `<button>` instead for keyboard accessibility and screen reader support.

```suggestion
<button type="button" onClick={handleClick} className={styles.card}>
```

---

### 2. [warning] `src/components/Card.module.css:18` — css
Hardcoded color `#333`. Use a design token instead.

```suggestion
  color: var(--color-text-primary);
```

---
(etc.)
```

Then use `AskUserQuestion` with these options:
- **Post all** — post every comment as-is
- **Post errors and warnings only** — skip nits and questions
- **Let me edit** — user will reply with instructions like "drop 3, 7" or "edit 2: [new text]"
- **Cancel** — post nothing

If the user chooses "Let me edit", wait for their instructions. They can:
- `drop N, M, ...` — remove specific comments by number
- `edit N: new text` — replace a comment's body
- `keep N, M, ...` — only post these specific comments
- Any combination of the above

Reconfirm the final set before posting.

---

## Phase 5 — Post comments

### GitHub branch

For each approved comment, POST to `/repos/<owner>/<repo>/pulls/<number>/comments` via `gh api`:

```
gh api -X POST /repos/<owner>/<repo>/pulls/<number>/comments \
  -f body="<comment body>" \
  -f commit_id="<headRefOid>" \
  -f path="<new path>" \
  -F line=<line> \
  -f side="RIGHT"   # RIGHT = new file (additions/modifications), LEFT = old file (deletions)
```

Pass `body` via HEREDOC if it contains newlines or backticks (suggestion blocks).

**Fallback**: if a positional comment fails (stale diff, line out of range), post as a general PR comment via the already-granted `gh api` (PR-level comments use the issues-comments endpoint): `gh api -X POST /repos/<owner>/<repo>/issues/<number>/comments -f body="**<path>:<line>** — <body>"`.

### GitLab branch

For each approved comment, post as an inline discussion using `mcp__gitlab__discussion_new_with_position`:

- `project_id`: the project path
- `merge_request_iid`: the MR IID
- `body`: the comment body (with suggestion block if applicable)
- `position_type`: `"text"`
- `base_sha`: from `diff_refs.base_sha`
- `start_sha`: from `diff_refs.start_sha`
- `head_sha`: from `diff_refs.head_sha`
- `old_path`: the file's old path from the diff
- `new_path`: the file's new path from the diff
- `new_line`: for additions/modifications on the new side
- `old_line`: for deletions on the old side

**Post sequentially** (not in parallel) on either platform to preserve ordering in the discussion thread.

**Fallback (GitLab)**: if a positional comment fails, fall back to `mcp__gitlab__discussion_new` as a general MR-level comment. Prefix the body with the file and line: `**{file}:{line}** — {original body}`.

---

## Phase 6 — Summary

After posting, report:

```
## Done

Posted {N}/{total} comments on {PR/MR title}
- {X} errors, {Y} warnings, {Z} nits, {W} questions
- {F} failed to post as inline (posted as general comments instead)
- {S} skipped (duplicates of existing discussions)

{link to PR/MR}
```
