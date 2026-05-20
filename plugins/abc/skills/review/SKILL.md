---
name: review
description: Review a GitHub PR or GitLab MR with craft-level attention to semantic HTML, CSS architecture, accessibility, TypeScript patterns, and code quality. Auto-detects platform from URL or git remote. Proposes inline diff comments, shows them for approval, only posts what the user approves. TRIGGER when the user says "/review", "review this PR/MR", "review <url>", or passes a PR/MR number.
argument-hint: "<pr-url> | <mr-url> | <number>"
model: opus
allowed-tools:
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
  - mcp__claude_ai_Linear__get_issue
---

# /review

Review a GitHub **pull request** or GitLab **merge request** with craft-level attention to semantic HTML, CSS architecture, accessibility, TypeScript patterns, and code quality. Auto-detects platform. Proposes inline diff comments, shows them for approval, posts only what the user approves.

**Input:** `$ARGUMENTS`

---

## Phase 0 — Detect platform and parse input

### Determine platform

Platform detection in order:

1. **URL with `github.com`** → `platform = github`
2. **URL with `gitlab.` host** (e.g. `gitlab.com`, self-hosted GitLab) → `platform = gitlab`
3. **Bare number** (e.g. `123`) → run `git remote get-url origin` in cwd; same rules as above against the remote URL. If cwd is not in a git repo → ask the user for a URL.
4. **No arguments** → ask for the PR/MR URL or number.

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

Apply the universal rules (below) plus any repo-specific rules to each diff hunk. For every issue found, generate a comment with:

- **severity**: `error` | `warning` | `nit` | `question`
- **category**: `a11y` | `css` | `typescript` | `test` | `quality` | `security`
- **file**: the new path of the file
- **line**: the line number in the new file (for additions/modifications) or old file (for deletions)
- **side**: `new` (for added/modified lines) or `old` (for removed lines)
- **body**: the comment text

### Actionable comments only

**Every comment must include a concrete fix or a specific question.** If you identify a potential issue but have no actionable suggestion (no code fix, no alternative approach, no specific question to ask), do not post the comment. "This could break someday" without a proposed solution is noise, not signal.

### Comment tone

Adapt tone by severity:
- **error**: Direct and clear. "This needs to change because..."
- **warning**: Suggestive. "Consider using X instead of Y because..."
- **nit**: Gentle. "Minor: could use X here for consistency"
- **question**: Curious. "Is this intentional? I'd expect X because..."

### Suggestion blocks

When you have a concrete fix, use the platform's suggestion syntax (both GitHub and GitLab support the same fenced block):

````
```suggestion
the corrected code here
```
````

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

**Fallback**: if a positional comment fails (stale diff, line out of range), post as a general PR comment via `gh pr comment <number> --body "**<path>:<line>** — <body>"`.

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

---

## Universal review rules

Apply these to all PRs/MRs regardless of platform or repo. Repo-specific rules from `.claude/review-rules.md` **augment** these — they do not replace them.

### Semantic HTML & accessibility

- `<div>` or `<span>` used where a semantic element fits: `<nav>`, `<main>`, `<section>`, `<article>`, `<aside>`, `<header>`, `<footer>`, `<figure>`, `<figcaption>`, `<time>`, `<mark>`
- Unnecessary wrapper `<div>` that exists only for styling and could be removed. Also flag wrapper elements whose only purpose is setting an inheritable CSS property (like `color`) — if the property can be set on the parent and inherited by children, the wrapper is unnecessary DOM bloat.
- `onClick` on a `<div>` or `<span>` — must be a `<button>` (for actions) or `<a>` (for navigation). If truly needed on a non-interactive element, require `role`, `tabIndex`, and `onKeyDown`.
- Missing keyboard support: interactive elements without `onKeyDown` or `onKeyUp` handlers.
- `:focus` used instead of `:focus-visible` (`:focus` shows focus rings on mouse click too).
- Missing ARIA: icon-only buttons without `aria-label`, toggles without `aria-expanded`, dialogs without `aria-modal`.
- `cursor: pointer` on `<button>` — browsers already handle this, it's unnecessary.
- Missing disabled state styling or `aria-disabled`.
- Images without meaningful `alt` text (empty `alt=""` is fine for decorative images).

### CSS

- **Hardcoded colors** (hex, rgb, hsl, named colors) — always flag. Must use design tokens. This is the single most common issue. When flagging, advise the author to use the existing token from the theme. If the existing token value doesn't match the desired color, the variable should be overridden within component scope following the repo's color scheme conventions (check repo rules for specifics). Do NOT suggest adding new tokens to theme files — defer to repo rules for how overrides should work.
- `!important` — almost always a code smell. Flag it.
- ID selectors (`#foo`) in stylesheets — specificity bomb, use classes.
- Deep nesting (>3 levels of selectors) — hard to override, refactor.
- Inline `style={{}}` — flag unless it's setting dynamic values (position, transform, CSS custom properties).
- `transition: all` — specify the exact property for performance and intentionality.
- Animations missing `prefers-reduced-motion` media query.
- Animations on layout-triggering properties (`width`, `height`, `top`, `left`, `margin`) — prefer `transform` and `opacity`.
- `z-index` without a comment explaining the stacking context.
- **Physical properties** — use CSS logical equivalents for RTL/internationalization support. Flag `margin-left`/`margin-right` → `margin-inline-start`/`margin-inline-end`, `padding-left`/`padding-right` → `padding-inline-start`/`padding-inline-end`, `left`/`right`/`top`/`bottom` → `inset-inline-start`/`inset-inline-end`/`inset-block-start`/`inset-block-end`, `border-left`/`border-right` → `border-inline-start`/`border-inline-end`. For `width`/`height` → `inline-size`/`block-size`, treat as a gentle recommendation (nit), not a warning — these are less widely adopted and can confuse developers. Exception: physical properties are acceptable when the direction is truly physical (e.g. a visual effect anchored to the screen edge, a `transform` offset).
- **Token semantic misuse** — using a token outside its intended purpose is as bad as hardcoding. For example, `--color-action-*` tokens are for interactive/clickable elements; using them for static text color is a semantic mismatch. Flag when a token's name clearly indicates a different purpose than how it's being used.
- **Primitive token misuse** — raw primitive/scale tokens (`--neutral-10`, `--white`, `--black`, `--green-50`, etc.) used directly in component styles when a semantic token exists (`--color-bg-primary`, `--color-bg-secondary`, `--color-text-primary`, etc.). Primitives describe *what the color is*; semantics describe *what it's for*. Components should use semantics so themes work correctly. Exception: primitive tokens are acceptable inside `light-dark()` calls where you're explicitly defining the light/dark pair.
- **Prefer `light-dark()` over `[data-color-scheme]` nesting** — when a property has adjacent light and dark values defined via `[data-color-scheme='dark'] &` or `[data-color-scheme='light'] &` selectors, prefer the `light-dark(light-value, dark-value)` CSS function instead. It's more concise, avoids selector nesting, and keeps the light/dark relationship co-located.
- **Redundant dark-mode selectors** — semantic design tokens (e.g. `--color-action-primary`, `--color-bg-primary`, `--color-text-*`) already switch values between light and dark modes. Wrapping them in `[data-color-scheme='dark'] &` selectors is redundant — the token handles the mode switch. Flag when a `[data-color-scheme]` selector only changes a value that's already a mode-aware semantic token.
- Magic numbers for spacing/sizing without explanation.

### Components & TypeScript

- Props type not exported, not named `{ComponentName}Props`, or uses `any`.
- Props don't extend the appropriate HTML element type (`ComponentPropsWithRef<'button'>`, etc.). However, `ComponentPropsWithoutRef` is acceptable by default — only flag it if a ref is actively needed and missing. Teams upgrade to `WithRef` deliberately when the need arises.
- Default exports — context-dependent. Check repo rules for exceptions (Next.js pages, Storybook stories). If no repo rules, flag as a question.
- Missing return type on exported functions.
- Untyped event handlers (`(e) => ...` without type annotation on `e`).
- `as` type assertions — **never suggest adding `as` casts** as a fix. If types are wrong, suggest fixing at the source: generics, type guards, correct interfaces, or narrowing. Casting papers over the problem.
- Unused imports or variables.
- **Variant names should be semantic, not visual.** Flag color-based variant names (`tip-purple`, `btn-blue`, `card-green`). Variants should describe purpose: `note`, `warning`, `error`, `success`, `info`. Colors can change; semantics are stable.

### Tests

- New component or logic without a corresponding test file.
- Tests that check implementation details (internal state, private methods) instead of behavior.
- Excessive snapshot tests (prefer explicit assertions).
- Test files with no assertions (just rendering).
- Tests that depend on execution order or share mutable state.

### Code quality

- **Bugs**: logic errors, off-by-one, null/undefined access without guards.
- **Security**: `dangerouslySetInnerHTML` without sanitization, URL injection, XSS vectors.
- Misleading variable/function names that don't match behavior.
- Commented-out code (should be deleted, not commented).
- Dead code / unused exports.
- `console.log` statements left in production code.
- Inconsistency with surrounding code patterns.

### Layout utilities

- If the repo has layout components (`Row`, `Column`, `Stack`, `Flex`) or utility classes, prefer them over custom CSS for simple flex layouts that don't need media queries. Defer to repo rules for specifics.

### Architectural boundaries

- **Content-specific styles in generic components** — if a component lives in a "ui-core", "primitives", or "headless" layer (i.e. it's meant to be generic and reusable), its CSS should not contain selectors that target specific content types or patterns. For example, `img[style*='--icon-url']` in a generic `TableCell` means the table primitive "knows" about the icon rendering technique — that's a leak. Content-specific styling belongs in the content-layer component that composes the primitive. Flag when a generic component's CSS reaches into its children's implementation details.
- **Fix at source, not caller** — layout workarounds (`maxWidth`, `overflow: hidden`, wrapper divs for containment) added to generic/shared renderers to fix overflow or sizing caused by a specific child component. The fix should be scoped to the component that causes the issue, not applied broadly to the renderer that hosts all content types. Flag when a generic renderer is modified to accommodate a single new component — the component should handle its own containment.
