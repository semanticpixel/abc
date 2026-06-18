---
name: scaffold-sub-issues-gh
description: GitHub · GitHub-Issues sibling of /abc:scaffold-sub-issues. Reads one or more PLAN-*.md files and turns them into a GitHub parent issue plus child issues, using a managed task-list-in-body for hierarchy and label conventions for state/dependencies. Either creates a new parent (auto-detect / new-parent mode) or adds children to an existing parent (when `<owner>/<repo>#<n>` is passed). Output is a parent issue URL you can paste into /abc:ship-issue-gh or /abc:ship-epic-gh. TRIGGER when the user says "/scaffold-sub-issues-gh", "create GitHub issues from this plan", "scaffold sub-issues for owner/repo#N", or passes a PLAN-*.md path while working on a GitHub-Issues-tracked project.
argument-hint: "<path-to-plan> | <owner>/<repo> <path-to-plan> | <owner>/<repo>#<n> <path-to-plan> [<more-plans>...] | (auto-detect latest PLAN-*.md in cwd or ~/.claude/plans)"
model: opus
allowed-tools:
  - Read
  - Glob
  - AskUserQuestion
  - Bash(ls:*)
  - Bash(pwd:*)
  - Bash(git remote:*)
  - Bash(gh auth status:*)
  - Bash(gh repo view:*)
  - Bash(gh label list:*)
  - Bash(gh label create:*)
  - Bash(gh issue view:*)
  - Bash(gh issue create:*)
  - Bash(gh issue edit:*)
  - Bash(gh issue list:*)
---

# /abc:scaffold-sub-issues-gh — Convert PLAN(s) to GitHub Issues

Take one or more `PLAN-*.md` files, parse their sub-tasks, propose a GitHub parent issue (or add children to an existing one) with a managed `## Sub-issues` task-list, `repo:` / `status:*` / `blocks:*` / `blocked-by:*` labels, and an optional `## Validation` gate, then create them after the user confirms.

The output of this skill is a **parent issue URL** (or `<owner>/<repo>#<n>` ID) you can paste straight into `/abc:ship-epic-gh` (parallel multi-repo) or `/abc:ship-issue-gh` (serial single-loop).

This is the GitHub-Issues sibling of `/abc:scaffold-sub-issues` (which targets Linear). The two are deliberately parallel skills — pick by tracker, not auto-detect. See `github-conventions.md` in this directory for the label scheme and task-list parsing rules used across the `-gh` family.

## Hard rules

- **Never create issues without an explicit confirmation gate.** Issue creation is write-heavy and visible to collaborators; the user must see the full proposed structure before any `gh issue create` call.
- **Never create new labels silently.** If a sub-task references `repo:<name>` that doesn't exist, surface it and ask whether to create the label or rename the sub-task. Same for `status:*` if those don't exist yet.
- **Never invent sub-tasks not present in the plan.** Parse what's there. If the plan is missing acceptance criteria or a `repo:`, ask the user — don't fabricate.
- **Sub-issues must be created sequentially, not in parallel.** Two concrete risks, not just ordering: (1) **mis-mapping returned issue numbers** — each `gh issue create` prints the new number on its own; firing several concurrently makes it easy to bind the wrong number to the wrong ST-N in the ST→`#<n>` map, corrupting the task-list refs and the dependency labels. (2) **secondary rate limits** — GitHub throttles rapid bursts of content-creating calls with a 403 secondary-rate error. Sequential creation keeps the number↔ST binding unambiguous and the request pace under the threshold.
- **When multiple plan files are provided, reconcile conflicts before building the tree.** Never silently pick one plan's version over another — surface contradictions via `AskUserQuestion`.
- The parent issue's description is the **full plan markdown** (concatenated if multiple) plus the managed `## Sub-issues` task-list section, not a summary. Reviewers should be able to read the parent and understand the full context.
- **Only touch labels in the declared namespaces** — `repo:*`, `status:*`, `blocks:*`, `blocked-by:*`. Never auto-add or remove user-authored labels outside these prefixes.

## Workflow

### Phase 0: Parse arguments + locate plans + detect host

`$ARGUMENTS` has four shapes — detect in order, first match wins.

**Path precedence (applies before shapes 2–3).** If the first token names an **existing file** (check with `ls`), or ends in `.md`, it is a plan path, not a repo/issue ref — skip to shape 4. This stops a relative plan path like `examples/PLAN-avatar-component.md` (which matches the `<owner>/<repo>` shape character-for-character) from being misparsed as an `owner/repo` arg. Shapes 2 and 3 below are also **full-token anchored** (`^…$`) so a token with a trailing `/path/...` segment can't partial-match.

1. **Empty** → auto-detect mode. Look for `PLAN-*.md` in cwd (newest by mtime wins), fall back to `~/.claude/plans/PLAN-*.md` (newest wins). If multiple candidates, ask the user to pick via `AskUserQuestion`. If none, abort with: "No PLAN-*.md found. Run /abc:plan first."
2. **First token fully matches `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+$`** (e.g. `semanticpixel/abc#42`) and is not an existing file → **existing-parent mode**. Treat the first token as the parent issue. Remaining tokens are plan file paths (all required, all must exist). This skill will add child issues to that parent's task-list instead of creating a new one.
3. **First token fully matches `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`** (a bare `<owner>/<repo>`), is not an existing file, and does not end in `.md` → **new-parent mode with explicit hub repo**. Remaining tokens are plan file paths.
4. **Otherwise** → all tokens are plan file paths (one or more). **New-parent mode with auto-detected hub repo** (from cwd's `git remote get-url origin` — must be a GitHub URL; if not, ask the user for an explicit `<owner>/<repo>`).

Read all selected plan files in full. Concatenate them in the order provided (Phase 1.5 handles conflicts).

**Auth pre-flight.** Run `gh auth status`. If not authed for the target host (`github.com` by default, or a GitHub Enterprise host if the hub repo's URL indicates one), halt with the exact re-auth command. Don't attempt issue creation against unauthed hosts.

**`gh` capability.** This skill relies on `--json body` support on `gh issue view`. No proactive `gh --version` probe — if a `gh issue view ... --json body` call fails because the flag is unsupported (very old `gh`), halt with reason `gh-too-old-for-json-body` and the upgrade command.

### Phase 1: Parse the plan structure

Parse each plan per the canonical grammar in [`../plan/plan-format.md`](../plan/plan-format.md) — the strict/loose formats, the sub-task block fields, the `(none)`/`(empty)`/omitted relations sentinel, and the validation-gate resolution order are all defined there (single-sourced so this skill and the Linear `scaffold-sub-issues` can't drift). If neither format matches, halt with the message that doc specifies.

**GitHub-specific deltas** (everything else follows `plan-format.md` verbatim):

- The per-sub-task `validation:` bullet (or a sub-task-level `## Validation`) becomes that child's manual-validation gate — the post-merge `blocked-verify` halt for `/abc:ship-issue-gh`. A top-level `## Validation` section is unattached; Phase 4 asks which sub-issue inherits it.
- `repo:<name>` maps to a GitHub `repo:<name>` label and routes to a same-owner repo by default. A fully-qualified `repo:<owner>/<name>` routes the child to a different owner's repo (the cross-owner case in Phase 2.2) — preserve the `<owner>/` prefix through to label creation and `gh issue create --repo`.

### Phase 1.5: Reconcile multiple plans (only if 2+ plans given)

Identical to the Linear sibling's Phase 1.5. Scan for:

- Same `ST-N` ID with different content.
- Same `repo:<name>` with different scope.
- Headings appearing in multiple plans with materially different prose.

For each conflict: `AskUserQuestion` side-by-side with the newer-by-mtime tagged **(Recommended)**. Bake the choice into the canonical structure for Phase 2 onward.

### Phase 2: Resolve GitHub context

In all modes:

1. **Hub repo.**
   - Existing-parent mode → hub = the parent's `<owner>/<repo>`.
   - Explicit new-parent mode → hub = the `<owner>/<repo>` arg.
   - Auto-detect → hub = `git remote get-url origin`, parsed to `<owner>/<repo>`.
2. **Repo existence + auth.** `gh repo view <owner>/<repo>` for the hub and for every unique `repo:<name>` in the plan that names a *different* repo (cross-repo case). Resolve `<name>` to `<owner>/<name>` if the same owner as the hub, else require the plan to use `<owner>/<name>` explicitly. Halt with a clear message if any repo doesn't exist or isn't accessible.
3. **Existing labels.** `gh label list --repo <owner>/<repo> --json name,color --limit 200` for the hub repo *and* for every distinct target repo. Compute the **missing labels** set:
   - **Hub repo** needs the **union of all `repo:*` labels** referenced by any sub-task — because the parent issue (created in the hub) carries that whole union as its labels (Phase 3's `labels: [<deduped union of all sub-task repo: labels>]`). So even a `repo:analytics-tools` whose children live in a *different* target repo must exist as a label in the hub repo, or applying the parent's label set fails.
   - **Each target repo** needs its own `repo:<name>` label (the one its children carry), plus `status:in-progress`, `status:in-review` (the only two `status:*` labels we manage; `pending` is absence-of-label, `merged`/`failed` map to closed-state).
   - `blocks:#<N>` and `blocked-by:#<N>` are created **per-edge in Phase 5**, not here — their names depend on resolved issue numbers we don't know yet.
4. **Existing-parent mode only.** `gh issue view <n> --repo <owner>/<repo> --json number,title,state,body,labels`. Capture body; parse any existing `<!-- ship-epic:sub-issues:start -->` ... `<!-- ship-epic:sub-issues:end -->` block for the collision check in Phase 3.

### Phase 2.5: cwd subdirectory advisory (soft warning)

For each unique `repo:<name>` referenced, check whether `<cwd>/<name>/` exists (`ls` in cwd). If missing, note for the Phase 7 advisory — don't halt. The user might invoke `/abc:ship-issue-gh` from a different cwd.

### Phase 3: Build the proposed issue tree

Compose the structure in memory:

```
Parent:
  hub_repo: <owner>/<repo>
  title: <plan title>           # new-parent mode only
  body: |
    <full plan markdown, concatenated if multiple>

    ## Sub-issues
    <!-- ship-epic:sub-issues:start -->
    - [ ] #<ST-1-placeholder> — <ST-1 title>
    - [ ] #<ST-2-placeholder> — <ST-2 title>
    - [ ] <owner>/<other-repo>#<ST-3-placeholder> — <ST-3 title>
    <!-- ship-epic:sub-issues:end -->
  labels: [<deduped union of all sub-task repo: labels>]

Sub-issues (in plan order):
  ST-1:
    target_repo: <owner>/<repo>          # may differ from hub (cross-repo case)
    title: <ST-1 title>
    body: |
      ## Scope
      <scope text>

      ## Acceptance criteria
      - <bullets>

      [optional ## Validation block, only on the chosen gate sub-issue]

      ---
      Parent: <hub-owner>/<hub-repo>#<parent-placeholder>
    labels: [repo:<name>]
    relations:
      blocks: [<ST-IDs>]
      blocked by: [<ST-IDs>]
  ST-2: …
```

**Existing-parent mode collision check.** Re-use the parent body fetched in Phase 2. If the parent already has a non-empty `## Sub-issues` block (one or more `- [ ]` / `- [x]` lines between the fence markers):

- `AskUserQuestion`: "Parent `<owner>/<repo>#<n>` already has N children in its task-list. **Halt** (default), **Append** more (new children land after existing ones), or **Show me the existing ones** before deciding?"
- On Halt → exit cleanly, no writes.
- On Append → proceed with Phase 4 but warn in the preview that ordering will be append-only.

### Phase 4: Show the user the proposed structure

Print a readable preview:

```
/abc:scaffold-sub-issues-gh — proposed GitHub structure

Mode: new-parent | existing-parent (<owner>/<repo>#<n>) | existing-parent (append)
Hub repo: <owner>/<repo>
Parent: <Title>                                # new-parent mode only
  Labels: repo:web-frontend, repo:analytics-tools
  Body: <2000-char preview>

Sub-issues:

  [ST-1] Add WidgetRow component to web frontend
    Target repo: <owner>/web-frontend
    Labels: repo:web-frontend
    Blocks: ST-3
    Blocked by: (none)

  [ST-2] Publish shared WidgetRow types in analytics-tools
    Target repo: <owner>/analytics-tools
    Labels: repo:analytics-tools
    Blocks: (none)
    Blocked by: (none)

  [ST-3] Wire WidgetRow into dashboard page  ← carries ## Validation gate
    Target repo: <owner>/web-frontend
    Labels: repo:web-frontend
    Blocks: (none)
    Blocked by: ST-1

Dependency graph:
  ST-2 → (independent)
  ST-1 → ST-3

Missing labels to create:
  in <owner>/web-frontend (hub):  status:in-progress, status:in-review, repo:web-frontend, repo:analytics-tools
  in <owner>/analytics-tools:     status:in-progress, status:in-review, repo:analytics-tools
cwd advisory: <cwd>/analytics-tools/ not found  (you'll need to invoke /abc:ship-issue-gh from a cwd containing this subdir)
# Note: the hub repo gets the *union* of all repo:* labels (the parent issue carries them all); each target repo gets only its own repo:<name>.
```

Then ask via `AskUserQuestion`:

1. **Confirm structure**:
   - **Create everything as shown** (Recommended)
   - **Edit before creating** — user replies with adjustments
   - **Create just the parent, skip sub-issues** — new-parent mode only
   - **Cancel**

2. **Validation gate** (only if no `## Validation` was attached in Phase 1, or there's a top-level Validation section that needs an owner):
   - "Which sub-issue should carry the `## Validation` section to trigger `/abc:ship-issue-gh`'s `blocked-verify` flow?" Default: last UI-touching sub-issue if detectable, else "none".

3. **Missing labels** (only if Phase 2 found any):
   - "These labels don't exist yet in the listed repos: `<list>`. Create them, or rename the sub-tasks?"

If "Edit before creating" — wait for user input, re-render the preview, re-ask.

### Phase 5: Create labels, parent (if needed), then sub-issues sequentially

1. **Missing labels first.** For each approved missing label, call `gh label create <name> --repo <target-repo> --color <hex> --description <text>`. Use the color scheme from `github-conventions.md`. Run per-repo (don't batch across repos — `gh label create` is per-repo).
2. **Parent (new-parent mode only).** Build the body with the `## Sub-issues` block containing **placeholder lines** (we'll patch in real numbers after Phase 5.3). Pipe the body on stdin (no `Write` tool — `--body-file -` reads stdin, stays inside the `gh issue create` grant): `gh issue create --repo <hub> --title <T> --body-file - --label <comma-list> <<'EOF'` … body … `EOF`. Capture the parent's issue number from the URL the command prints.
3. **Sub-issues, sequentially.** For each sub-task in plan order:
   - Build the description: `## Scope`, `## Acceptance criteria`, plus the `## Validation` block on the chosen gate sub-issue, plus a `Parent: <hub>/<parent-num>` trailer.
   - Call `gh issue create --repo <target-repo> --title <T> --body-file - --label "repo:<name>" <<'EOF'` … description … `EOF` (body piped on stdin, same `--body-file -` pattern as the parent). **Wait for the response before issuing the next call.** Capture the new number from the URL.
   - Build the ST-N → `<owner>/<repo>#<n>` map.
4. **Patch the parent body.** Re-fetch (`gh issue view <parent-num> --repo <hub> --json body`), replace the placeholder lines between the fence markers with real `- [ ] <ref> — <title>` lines (use `#<n>` for same-repo, `<owner>/<repo>#<n>` for cross-repo), then pipe the patched body on stdin: `gh issue edit <parent-num> --repo <hub> --body-file - <<'EOF'` … body … `EOF`. In append mode, *insert* new lines after the existing block contents (don't touch the existing lines).
5. **Wire dependency labels.** For each sub-issue with `blocks: [ST-X, ST-Y]`:
   - Compute the labels: `blocks:#<X-resolved>` and `blocks:#<Y-resolved>` (use the resolved per-repo number; cross-repo `blocks` uses `blocks:<owner>/<repo>#<n>` form).
   - Create the labels if they don't exist yet (`gh label create` per target repo). These are per-edge — fine to accumulate; they're cheap.
   - `gh issue edit <n> --repo <target-repo> --add-label "blocks:#<X>"`.
   - Same for `blocked by`: `blocked-by:#<N>` label on the dependent sub-issue.

### Phase 6: Self-check

1. `gh issue view <parent-num> --repo <hub> --json body` — confirm the `## Sub-issues` block contains every newly created sub-issue's ref, in plan order.
2. For each created sub-issue: `gh issue view <n> --repo <target> --json labels` — confirm the expected `repo:`, `blocks:*`, `blocked-by:*` set is present.
3. For new-parent mode, confirm the parent body's first H1 matches the plan title (catches accidental body mangling during the patch).

If any check fails, surface the diff between expected and actual to the user and recommend a manual fix; do not auto-retry destructive edits.

### Phase 7: Print the handoff

```
✓ Created parent: <owner>/<repo>#<N> "<Title>"             # new-parent mode
✓ Added 5 children to <owner>/<repo>#<N> "<Title>"         # existing-parent mode
✓ Wired 2 dependency edges
✓ Created 6 new labels (status:in-progress, status:in-review, repo:web-frontend, repo:analytics-tools, blocks:#42, blocked-by:#42)

Sub-issues (plan order — what /abc:ship-issue-gh will walk):
  1. <owner>/web-frontend#42  repo:web-frontend
  2. <owner>/analytics-tools#7  repo:analytics-tools
  3. <owner>/web-frontend#43  repo:web-frontend  ← carries ## Validation gate

Next:
  → /abc:ship-issue-gh <owner>/<repo>#<N>       (serial single-loop; recommended)
  → /abc:ship-epic-gh <owner>/<repo>#<N>        (parallel multi-repo; faster if relations allow)

Parent URL: https://github.com/<owner>/<repo>/issues/<N>
```

If Phase 2.5 flagged any missing cwd subdirectories, repeat the advisory:

```
⚠ Heads up: <cwd>/<repo-name>/ is missing.
  /abc:ship-issue-gh resolves repo: labels against subdirectories of cwd.
  Invoke it from a cwd that has each <repo-name>/ as a subdirectory,
  or clone the missing repos first.
```

## Notes on edge cases

- **Sub-task with no acceptance criteria**: ask the user to add them in the plan file, then re-run. AC is required for `/abc:ship-issue-gh` to know when an issue is done.
- **Circular blocks** (ST-1 blocks ST-2, ST-2 blocks ST-1): abort with a clear cycle description. The label scheme allows it but the dependency graph is unworkable.
- **Plan references a repo that has no sub-task**: ignore — the parent's label union covers it.
- **Multiple plans in cwd**: ask the user to pick (Phase 0 auto-detect).
- **Two plans contradict on a structural decision**: Phase 1.5 surfaces via `AskUserQuestion`, recommends newer plan by mtime.
- **Parent has existing children, user picks Append**: warn that new children land *after* existing task-list lines. If the user wants new ones first, they edit the parent body manually after the skill finishes.
- **Loose-format plan with no `repo:` tag on a sub-task**: halt and ask the user to add it. The skill won't guess.
- **Cross-repo with mismatched owners**: if the plan says `repo:other-org/foo` and the hub repo's owner is `our-org`, surface and confirm the cross-org wiring before any `gh repo view`. Cross-org task-list autolinks work, but the visual is more disruptive — make sure the user intended it.
- **GitHub Enterprise host**: derive from the hub repo URL (`gh repo view` honors `--repo` with full host prefix). All `gh` calls inherit the same host because `--repo` carries it. Don't mix hosts in a single invocation — Phase 0 halts if cross-host is implied.
- **`gh issue create` rate limits**: secondary rate limits on rapid issue creation. The sequential pattern in Phase 5.3 + the natural pacing of `--body-file` reads should keep us well under, but if a 403 secondary rate is returned, halt and surface — don't retry.
