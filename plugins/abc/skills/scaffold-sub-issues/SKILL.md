---
name: scaffold-sub-issues
description: Read one or more PLAN-*.md files and turn them into Linear sub-issues. Either creates a new parent issue from the plan (auto-detect mode) or adds sub-issues to an existing parent (when a parent ID is passed). Handles repo labels, blocks/blocked-by relations, and the manual-validation gate for /abc:ship-issue. Output is a parent ID you can paste into /abc:ship-issue or /abc:ship-epic. TRIGGER when the user says "/scaffold-sub-issues", "create Linear issues from this plan", "scaffold sub-issues for PARENT-ID", or passes a PLAN-*.md path.
argument-hint: "<path-to-plan> | <parent-id> <path-to-plan> [<more-plan-paths>...] | (auto-detect latest PLAN-*.md in cwd or ~/.claude/plans)"
model: opus
allowed-tools:
  - Read
  - Glob
  - AskUserQuestion
  - Bash(ls:*)
  - Bash(pwd:*)
  - mcp__claude_ai_Linear__list_teams
  - mcp__claude_ai_Linear__list_projects
  - mcp__claude_ai_Linear__list_issue_labels
  - mcp__claude_ai_Linear__list_issues
  - mcp__claude_ai_Linear__save_issue
  - mcp__claude_ai_Linear__create_issue_label
  - mcp__claude_ai_Linear__get_issue
  - mcp__claude_ai_Linear__list_users
---

# /abc:scaffold-sub-issues — Convert PLAN(s) to Linear sub-issues

Take one or more `PLAN-*.md` files, parse their sub-tasks, propose a Linear parent issue (or add to an existing one) with sub-issues + dependency edges + `repo:` labels + an optional `## Validation` gate, then create them after the user confirms.

The output of this skill is a **parent issue ID** you can paste straight into `/abc:ship-epic` (parallel multi-repo) or `/abc:ship-issue` (serial single-repo loop).

## Hard rules

- **Never create Linear issues without an explicit confirmation gate.** Issue creation is write-heavy and visible to teammates; the user must see the full proposed structure before any `save_issue` call.
- **Never create new Linear labels silently.** If a sub-task references `repo:<name>` that doesn't exist as a label, surface it and ask whether to create the label or rename the sub-task.
- **Never invent sub-tasks not present in the plan.** Parse what's there. If the plan is missing acceptance criteria or a repo, ask the user — don't fabricate.
- **Sub-issues must be created sequentially, not in parallel.** Linear's `createdAt` is the fallback sort key when `blocks`/`blocked by` aren't read by the consumer (e.g. `/abc:ship-issue` walks `createdAt` ascending). Parallel `save_issue` calls can collide at sub-second precision and scramble walk order.
- **When multiple plan files are provided, reconcile conflicts before building the tree.** Never silently pick one plan's version over another — surface contradictions via `AskUserQuestion`.
- The parent issue's description is the **full plan markdown** (concatenated if multiple), not a summary. Reviewers should be able to read the parent and understand the full context.

## Workflow

### Phase 0: Parse arguments + locate plans

`$ARGUMENTS` has three shapes — detect in order, first match wins:

1. **Empty** → auto-detect mode. Look for `PLAN-*.md` in cwd (newest by mtime wins), fall back to `~/.claude/plans/PLAN-*.md` (newest wins). If multiple candidates, ask the user to pick via `AskUserQuestion`. If none, abort with: "No PLAN-*.md found. Run /abc:plan first."
2. **First token matches `[A-Z]+-\d+`** (e.g. `PROJ-45`) → **existing-parent mode**. Treat the first token as the parent Linear issue ID. Remaining tokens are plan file paths (all required, all must exist). This skill will add sub-issues to that parent instead of creating a new one.
3. **Otherwise** → all tokens are plan file paths (one or more). Resolve relative to cwd or as absolute paths. This is **new-parent mode** with explicit input.

Read all selected plan files in full. Concatenate them in the order provided (Phase 1.5 handles conflicts).

### Phase 1: Parse the plan structure

Extract per plan. Two supported formats — prefer strict, accept loose:

**Strict format** (`/abc:plan` output) — preferred:

- **Title** (the H1 minus `PLAN:`).
- **Context** section text.
- **Approach** section text.
- **Sub-tasks** — for each `### ST-N: <title>` block, parse:
  - `repo:` (required — error if missing)
  - `scope:` (required)
  - `acceptance criteria:` (list of bullets, required)
  - `blocks:` (list of ST-IDs, optional)
  - `blocked by:` (list of ST-IDs, optional)
- **Validation** section text (parent-level).
- **Out of scope** section text.

**Loose format** — fallback for plans that weren't produced by `/abc:plan` (e.g. `~/.claude/plans/*.md` drafts or hand-written `PLAN-*.md`):

- Sub-task headings like `## Sub-issue N — <repo>: <title>`. Required: `repo:` (in heading or first-line tag). Optional: scoped sub-sections beneath (`### Description`, `### Changes`, `### Acceptance criteria`, `### Tests`, `### Local checks`, `### Files to touch`, `## Validation`).
- If acceptance criteria are missing from a sub-task, ask the user before proceeding — better to fix the source than to fabricate. Don't auto-fill.

**Validation gate detection.** Look for `## Validation` headings:
- Inside a sub-task's body → that sub-task carries the manual-validation gate (post-merge `blocked-verify` halt for `/abc:ship-issue`).
- At the top level of the plan → unattached; in Phase 4 ask which sub-issue should inherit it.

If **neither format** is detected → halt with "I couldn't parse sub-tasks from this plan. Expected `### ST-N:` blocks or `## Sub-issue N — <repo>:` headings."

### Phase 1.5: Reconcile multiple plans (only if 2+ plans given)

Scan the parsed plans for conflicting decisions:

- Same `ST-N` ID with different content.
- Same `repo:<name>` with different scope.
- Headings appearing in multiple plans with materially different prose (e.g. one plan says "experiment-gated", another says "unconditional").

For each conflict:

- `AskUserQuestion` with both options side-by-side. Tag the option from the newer plan (by file mtime) as **(Recommended)**.
- Bake the user's choice into the canonical structure used by Phase 2 onward.

If no conflicts detected, fall through silently.

### Phase 2: Resolve Linear context

Two branches depending on mode:

**Existing-parent mode** (parent ID was passed in Phase 0):

1. `mcp__claude_ai_Linear__get_issue id=<parent-id> includeRelations: true`. Capture `team`, `project`, existing labels.
2. Use the parent's team + project as defaults for all new sub-issues.

**New-parent mode** (no parent ID):

1. **Linear team** — `mcp__claude_ai_Linear__list_teams`. If multiple, ask the user. Cache the choice.
2. **Project** (optional) — `mcp__claude_ai_Linear__list_projects` with the team filter. If the plan title hints at a project (matches a project name), pre-select it. Otherwise leave blank and ask.

In both modes:

3. **`repo:` labels** — `mcp__claude_ai_Linear__list_issue_labels team=<team>`. Match each sub-task's `repo:<name>` to an existing label. Track missing labels for Phase 4 approval — do not create here.

### Phase 2.5: cwd subdirectory advisory (soft warning)

For each unique `repo:<name>` referenced in the parsed structure, check whether `<cwd>/<name>/` exists (`ls` in cwd). If missing, note it for the Phase 7 advisory — don't halt. The user might invoke `/abc:ship-issue` from a different cwd than where they're running this skill.

### Phase 3: Build the proposed issue tree

Compose the structure in memory:

```
Parent:
  team: <resolved team>
  project: <resolved or null>
  title: <plan title>           # new-parent mode only; existing-parent skips this
  description: <full plan markdown, concatenated if multiple>
  labels: [<deduped union of all sub-task repo labels>]

Sub-issues (in plan order):
  ST-1 (or Sub-issue 1):
    title: <ST-1 title>
    description: |
      ## Scope
      <scope text>
      ## Acceptance criteria
      - <bullets>
      [optional ## Validation block, only on the chosen gate sub-issue]
    parent: <parent ID, set on creation>
    labels: [repo:<name>]
    relations:
      blocks: [<ST-IDs>]
      blocked by: [<ST-IDs>]
  ST-2: …
```

**Existing-parent mode collision check.** Also call `mcp__claude_ai_Linear__list_issues parentId=<parent-id> limit=50`. If the parent already has sub-issues:

- `AskUserQuestion`: "Parent `<parent-id>` already has N sub-issues. **Halt** (default), **Append** more (warning: createdAt order will be sandwiched after the existing ones), or **Show me the existing ones** before deciding?"
- On Halt → exit cleanly, no writes.
- On Append → proceed with Phase 4 but warn in the preview.

### Phase 4: Show the user the proposed structure

Print a readable preview:

```
/abc:scaffold-sub-issues — proposed Linear structure

Mode: new-parent | existing-parent (<PARENT-ID>) | existing-parent (append)
Parent: <Title>
  Team: <Team>
  Project: <Project or "none">
  Labels: repo:web-frontend, repo:analytics-tools
  Description: <2000-char preview>

Sub-issues:

  [ST-1] Add WidgetRow component to web frontend
    Labels: repo:web-frontend
    Blocks: ST-3
    Blocked by: (none)

  [ST-2] Publish shared WidgetRow types in analytics-tools
    Labels: repo:analytics-tools
    Blocks: (none)
    Blocked by: (none)

  [ST-3] Wire WidgetRow into dashboard page  ← carries ## Validation gate
    Labels: repo:web-frontend
    Blocks: (none)
    Blocked by: ST-1

Dependency graph:
  ST-2 → (independent)
  ST-1 → ST-3

Missing labels to create: repo:web-frontend  (will prompt)
cwd advisory: <cwd>/analytics-tools/ not found  (you'll need to invoke /abc:ship-issue from a cwd containing this subdir)
```

Then ask via `AskUserQuestion`:

1. **Confirm structure**:
   - **Create everything as shown** (Recommended)
   - **Edit before creating** — user replies with adjustments
   - **Create just the parent, skip sub-issues** — for when sub-task scoping isn't ready (new-parent mode only)
   - **Cancel**

2. **Validation gate** (only if no `## Validation` was attached in Phase 1, or there's a top-level Validation section that needs an owner):
   - "Which sub-issue should carry the `## Validation` section to trigger `/abc:ship-issue`'s `blocked-verify` flow?" Default: last UI-touching sub-issue if detectable, else "none".

3. **Missing labels** (only if Phase 2 found any):
   - "These `repo:` labels don't exist yet: `<list>`. Create them, or rename the sub-tasks?"

If "Edit before creating" — wait for user input, re-render the preview, re-ask.

### Phase 5: Create labels, parent (if needed), then sub-issues sequentially

1. **Missing labels first.** For each approved missing label, call `mcp__claude_ai_Linear__create_issue_label` with `teamId=<team-id>`. Capture each new label ID.
2. **Parent (new-parent mode only).** Call `mcp__claude_ai_Linear__save_issue` with `team`, `project`, `title`, `description` (full plan markdown), `labels`. Capture the new parent ID.
3. **Sub-issues, sequentially.** For each sub-task in plan order:
   - Build the description: include `## Scope`, `## Acceptance criteria`, plus the `## Validation` block on the chosen gate sub-issue.
   - Call `mcp__claude_ai_Linear__save_issue` with `parentId`, `team`, `project` (if any), `title`, `description`, `labels`.
   - **Wait for the response before issuing the next call.** Do not parallelize. Linear's `createdAt` ordering is the fallback walk order for `/abc:ship-issue`; parallel creates collide at sub-second precision and scramble order.
   - Capture each returned sub-issue ID into an ST-N → ID map.
4. **Relations pass.** After all sub-issues exist, wire `blocks` / `blocked by` relations in a second pass. For each sub-issue with `blocks: [ST-X, ST-Y]`, call `mcp__claude_ai_Linear__save_issue id=<sub-issue-id> blocks: [<X-id>, <Y-id>]`. Same for `blocked by` via `blockedBy:`. (These fields are append-only per the `save_issue` schema — safe to call after creation.)

### Phase 6: Self-check

1. `mcp__claude_ai_Linear__list_issues parentId=<parent-id> orderBy=createdAt limit=50`. Returns sub-issues in descending order — reverse to get ascending.
2. Verify count matches (expected = plan sub-tasks created in this run; in append mode, expected = original count + new count).
3. Verify IDs match the ST-N → ID map from Phase 5.
4. Verify `createdAt` timestamps are strictly increasing among newly created sub-issues. If any two share the same second → log a warning (consumer might still walk in unspecified order); the user can manually reorder by editing in Linear or by re-running with a comma-separated list to `/abc:ship-issue`.

### Phase 7: Print the handoff

```
✓ Created parent: <PARENT-ID> "<Title>"             # new-parent mode
✓ Added 5 sub-issues to <PARENT-ID> "<Title>"       # existing-parent mode
✓ Wired 2 dependency links
✓ Created 1 new repo: label

Sub-issues (createdAt order — what /abc:ship-issue will walk):
  1. <SUB-ID-1> <repo:foo>  <URL>
  2. <SUB-ID-2> <repo:bar>  <URL>
  3. <SUB-ID-3> <repo:baz>  <URL>  ← carries ## Validation gate

Next:
  → /abc:ship-issue <PARENT-ID>       (serial single-loop; recommended)
  → /abc:ship-epic <PARENT-ID>        (parallel multi-repo; faster if no relations)

Linear link: <parent URL>
```

If Phase 2.5 flagged any missing cwd subdirectories, repeat the advisory:

```
⚠ Heads up: <cwd>/<repo-name>/ is missing.
  /abc:ship-issue resolves repo: labels against subdirectories of cwd.
  Invoke it from a cwd that has each <repo-name>/ as a subdirectory,
  or clone the missing repos first.
```

## Notes on edge cases

- **Sub-task with no acceptance criteria**: ask the user to add them in the plan file, then re-run. AC is required for `/abc:ship-issue` to know when a ticket is done.
- **Circular blocks** (ST-1 blocks ST-2, ST-2 blocks ST-1): abort with a clear cycle description. Linear allows the relations, but the dependency graph is unworkable.
- **Plan references a repo that has no sub-task**: ignore — the parent's label union covers it.
- **Multiple plans in cwd**: ask the user to pick (Phase 0 auto-detect).
- **Two plans contradict on a structural decision** (e.g. one says split CMS into helper+UI, the other says one bundled sub-issue): Phase 1.5 surfaces via `AskUserQuestion`, recommends newer plan by mtime.
- **Parent has existing sub-issues, user picks Append**: warn that new sub-issues will land *after* existing ones in createdAt order, which means `/abc:ship-issue` will walk old → new. If the user wants new ones to go first, they need to manually reorder in Linear (no MCP exposes `sortOrder`).
- **Loose-format plan with no `repo:` tag on a sub-task**: halt and ask the user to add it. The skill won't guess.
- **User wants to update an existing parent's description** rather than add sub-issues — out of scope for v1. Tell them to edit in Linear directly.
- **createdAt collision** (two sub-issues share the same second): log a warning; the consumer's walk order is unspecified between collisions. Suggest comma-separated explicit ordering to `/abc:ship-issue` as a workaround.
