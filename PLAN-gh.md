# Plan: GitHub-Issues siblings for `scaffold-sub-issues`, `ship-issue`, `ship-epic`

## Context

The user's personal projects live on GitHub, currently in a single repo but moving toward a UI library + N consumer projects (multi-repo, hub-repo shape). Signing up for personal Linear was considered and rejected: it fragments GitHub-native workflow, adds an ongoing context-switch tax, and isn't necessary for the hub-repo pattern the user is actually heading toward.

Instead: build **parallel `-gh` siblings** to the three tracker-coupled skills. The Linear-flavored originals stay untouched (still used for work projects on Linear). The new skills target GitHub Issues + `gh` CLI + (optionally) Projects V2.

User preference (stated explicitly): **parallel skills, not auto-detect**. Cleaner separation, each skill is focused.

## Locked decisions (recap from conversation)

- Three new skills: `scaffold-sub-issues-gh`, `ship-issue-gh`, `ship-epic-gh`.
- Originals (`scaffold-sub-issues`, `ship-issue`, `ship-epic`) stay unchanged.
- `plan`, `pr`, `review`, `review-sweep` are tracker-agnostic — no changes.
- **No personal Linear account.** Personal work goes end-to-end through GitHub.
- **No tracker abstraction layer in the originals.** Duplication is accepted; the cost of unifying two backends inside one skill outweighs the benefit.

## Capability findings (from Phase 1 exploration)

### What `gh` + GitHub Issues give us cleanly

| Feature | Coverage |
|---|---|
| Issue CRUD (create, view, edit, close, reopen, comment) | `gh issue *` — full |
| Issue state + state_reason | `gh issue edit`, `gh issue close --reason completed/not_planned` |
| Labels + milestones + assignees | `gh issue edit --add-label / --milestone / --assignee` |
| List comments with timestamps | `gh api /repos/.../issues/{n}/comments` (no native `gh` wrapper for list) |
| HTML-comment markers (`<!-- ship-issue:* -->`) | Preserved through API round-trip — identical pattern to Linear |
| Branch creation linked to issue | `gh issue develop --name <custom>` (default format undocumented, so we'll always pass `--name`) |
| Auto-close from PR | `Closes #N` (same-repo), `Closes owner/repo#N` (cross-repo) — works everywhere |

### What GitHub *does NOT* have

| Gap | Impact | Workaround |
|---|---|---|
| **Native sub-issues API** (REST or GraphQL Issue-level) | Can't programmatically attach issue B as child of issue A | Task-list-in-body convention with autolinked `- [ ] #N` references. GitHub renders these as live status (auto-checks when child closes). |
| **Typed relations** (`blocks` / `blocked by`) | ship-epic-gh can't build DAG from native data | Label convention: `blocks:#N`, `blocked-by:#N`. Parsed from each sub-issue's labels at Phase 1 of ship-epic-gh. |
| **Rich state machine** (In Progress / In Review distinct from open) | Linear has 5 named states; GitHub has open/closed + state_reason | Label-based emulation: `status:in-progress`, `status:in-review`. (Projects V2 status field is an alternative but requires per-project board setup — overkill for personal use.) |
| **`gitBranchName` field** | No native branch-name on the issue | Derive: `<issue-number>-<kebab-title>` (e.g. `42-add-button-primitive`). Sanitize to ASCII. |
| **Workspace-scoped issues** | All sub-issues for a parent must live somewhere; can't be in a free-floating workspace | Hub-repo pattern: pick one repo to hold parents (typically the UI library or a designated "planning" repo). Sub-issues can be same-repo (simplest) or cross-repo via `owner/repo#N` links. |

## Architecture

**Per-skill conventions doc** — each `-gh` skill ships with a `github-conventions.md` supporting file alongside its SKILL.md, documenting the label scheme and task-list parsing rules. Inlined in each skill rather than shared across skills (skills can have supporting files, but cross-skill imports aren't a documented pattern for personal plugins — and small duplication is cheaper than the fragility of remote references).

### State-machine emulation (label-based)

| Linear state | GitHub Issues representation |
|---|---|
| `Backlog` | `state=open`, no `status:*` label |
| `In Progress` | `state=open` + label `status:in-progress` |
| `In Review` | `state=open` + label `status:in-review` |
| `Done` | `state=closed`, `stateReason=completed` |
| `Canceled` | `state=closed`, `stateReason=not_planned` |

- Status labels auto-created in the target repo on first use (prompts user via `AskUserQuestion` if missing).
- `repo:*` labels (existing convention) carry over unchanged.
- Skill never touches labels outside the `status:*` namespace and the user-declared `repo:*` set — won't clutter the repo.

### Hierarchy emulation (task-list-in-body)

Parent issue body has a managed `## Sub-issues` section:

```markdown
## Sub-issues
<!-- ship-epic:sub-issues:start -->
- [ ] #42 — Tokens module (UI library)
- [x] #41 — Bootstrap project (UI library)
- [ ] luistorres/consumer-app#7 — Adopt v2 tokens
<!-- ship-epic:sub-issues:end -->
```

- GitHub autolinks `#42` and `owner/repo#42`, rendering title + state inline.
- Checkbox auto-updates to `[x]` when the referenced issue closes (GitHub native).
- Skill parses between the marker comments — never edits user-authored content elsewhere in the body.
- `ship-epic-gh` walks the list to discover sub-issues; works for both same-repo and cross-repo.

### Dependency expression (for `ship-epic-gh`)

For the rare cases where sub-issue B depends on sub-issue A:

- Author labels sub-issue B with `blocks:#N` or `blocked-by:#N` (matches across either direction).
- `ship-epic-gh` Phase 1 parses these labels into a directed graph.
- Cycle detection: identical DFS algorithm as the Linear version.
- Across repos: `blocked-by:owner/repo#N` works the same way.

### Cross-repo strategy (hub-repo pattern)

- Designate one repo as the "hub" (typically the most coordinating one — e.g. the UI library repo). Parent issue lives there.
- Sub-issues can be:
  - **All in hub repo** (simplest, default for the user's current scale).
  - **Distributed across work-repos** (e.g. UI library has sub-issue #1, consumer-app has sub-issue #7, all linked from parent body).
- Skill resolves each sub-issue's repo from the task-list link format; passes `--repo owner/repo` to `gh issue *` calls.

## Per-skill design

### Skill 1 — `scaffold-sub-issues-gh`

Input shapes (Phase 0):
- **`<plan-path>`** → new-parent mode, auto-detect hub repo from cwd's git remote.
- **`<owner>/<repo> <plan-path>`** → new-parent mode, explicit hub repo.
- **`<owner>/<repo>#<n> <plan-path> [<more-plans>...]`** → existing-parent mode (add sub-issues to parent #n in that repo).
- Empty arg → auto-detect plan in cwd / `~/.claude/plans` (same as Linear sibling).

Phase 1 — parse plan structure: **unchanged from Linear sibling.** Strict `### ST-N:` format preferred, loose `## Sub-issue N — <repo>:` fallback accepted.

Phase 1.5 — multi-plan reconciliation: **unchanged.**

Phase 2 — resolve GitHub context:
- `gh auth status` — confirm authed for the hub repo's host (github.com or GitHub Enterprise host).
- For each unique `repo:<name>` in the plan, verify the repo exists via `gh repo view <owner>/<name>` (or current org from `gh repo view`).
- List existing labels in hub repo via `gh label list --json name,color`.
- Compute missing labels (`repo:*`, `status:*`, optionally `blocks:*` / `blocked-by:*`).

Phase 3 — collision check:
- If existing-parent mode: `gh api /repos/.../issues/<n>` → parse body for existing `<!-- ship-epic:sub-issues:start -->` section. If present, offer append/halt/replace.

Phase 4 — preview with new questions:
- "Create these missing labels in `<owner>/<repo>`: `status:in-progress`, `status:in-review`, `repo:ui-library`, …?"
- "Which sub-issue carries the `## Validation` gate (for `ship-issue-gh` blocked-verify)?"

Phase 5 — execute:
1. Create missing labels via `gh label create --color <hex> --description <text>`.
2. Create parent (new-parent mode) via `gh issue create --title <T> --body <plan markdown> --label <list>`.
3. Create sub-issues sequentially. Each: `gh issue create --title <T> --body <T> --label "repo:<name>,blocked-by:#<parent>" --repo <target-repo>` (for cross-repo) or omit `--repo` for same-repo.
4. Capture each created issue's number from `gh issue create`'s output.
5. **Build parent body's `## Sub-issues` section** by editing parent body via `gh issue edit <n> --body <updated>`. Use the marker comments as fences.
6. **Wire dependency labels** in a second pass: for each sub-issue with `blocks: ST-X`, `gh issue edit <n> --add-label "blocks:#<X-resolved-number>"`.

Phase 6 — self-check: re-fetch parent body, verify task-list contains all created issue numbers in correct order. Verify each sub-issue's labels include the expected `blocks:*` / `blocked-by:*` set.

Phase 7 — handoff:
```
✓ Created parent: #<N> in <owner>/<repo>: <title>
✓ Created 5 sub-issues: #42, #43, #44, #45, #46
✓ Wired 2 dependency edges
✓ Created 4 labels (status:in-progress, status:in-review, repo:ui, repo:consumer)

Next:
  → /abc:ship-issue-gh <owner>/<repo>#<N>       (serial single-loop; recommended for personal work)
  → /abc:ship-epic-gh <owner>/<repo>#<N>        (parallel multi-issue coordinator)

Parent URL: https://github.com/<owner>/<repo>/issues/<N>
```

### Skill 2 — `ship-issue-gh`

Input shapes (Phase 0):
- **`<owner>/<repo>#<n>`** — single issue.
- **`#<n>`** when in a git repo — single issue, repo inferred from origin.
- **`<owner>/<repo>#<n>,<owner>/<repo>#<m>`** — comma-list (each must include repo prefix for unambiguity across cross-repo lists).
- **`<owner>/<repo>#<n>`** where the issue is a parent → walk task-list children in order.
- **`milestone:<owner>/<repo>/<milestone-number-or-name>`** — milestone expansion: `gh issue list --repo <owner>/<repo> --milestone <id> --state all --json number,title,state,createdAt`.

Phase 0.5 (self-arm /loop): **identical to Linear sibling.** Cron-entry match rule reuses the same logic.

Phase 1 — resolve each item (platform + repo):
- For GitHub mode, repo is encoded in the ID. Cwd's `<repo-name>/` subdirectory must exist (same `repo:<name>` label convention; the label still drives the workdir mapping when sub-issues are cross-repo).

Phase 2 — pick next item: **unchanged.**

Phase 3 — state derivation:
- `gh issue view <n> --repo <owner>/<repo> --json number,title,state,stateReason,labels,body,closedAt,closedByPullRequestsReferences,milestone`
- `gh api /repos/<owner>/<repo>/issues/<n>/comments` — for skill markers.
- Map to state table per the label scheme:
  - `state=open`, no `status:*` → `pending` or `implementing` (use marker comments to disambiguate).
  - `state=open` + `status:in-progress` → `implementing` if no PR, `fixing`/`pr-open` if PR open.
  - `state=open` + `status:in-review` → derive from PR state (rows 3, 3a, 3b, 4 unchanged).
  - `state=closed`, `stateReason=completed` → `merged` (or `blocked-verify` if `## Validation` in description and no `verify:passed` marker).
  - `state=closed`, `stateReason=not_planned` → `failed`.
- PR/MR discovery: `gh pr list --search "linked:<n>"` plus `closedByPullRequestsReferences` field.

Phase 4 — state handlers:
- `pending → implementing`:
  - `gh issue edit <n> --add-label status:in-progress --remove-label status:in-review`
  - Branch: derive from issue title + number (`<n>-<kebab-title>`, ASCII-only). Optionally call `gh issue develop --name <derived> --base main` to register the link, but not required.
  - Comment: `gh issue comment <n> --body '<!-- ship-issue:event:started --> 🚢 ship-issue started.'`
- `implementing → pr-open`:
  - PR body MUST include `Closes <owner>/<repo>#<n>` (cross-repo aware).
  - `gh issue edit <n> --add-label status:in-review --remove-label status:in-progress`
- `fixing`: identical to Linear sibling — pulls the failing checks via `gh pr checks --json` (already platform-agnostic).
- `merged`:
  - `## Validation` gate check: search description for the heading (same regex as Linear sibling).
  - If gated: stay open, transition to `blocked-verify`. Add comment with inlined validation steps. (Don't close yet.)
  - If clean: `gh issue close <n> --reason completed`. Comment with `<!-- ship-issue:event:merged --> ✅ Merged: <PR URL>.`
- `failed`: `gh issue close <n> --reason not_planned`. Comment with failure reason.
- `blocked-user`: same as Linear, comment only — no state change.

Phase 5 — escape hatches: **identical to Linear sibling.** Three-strikes counter uses comment markers, which work identically in GitHub.

Phases 6–8: **identical** (cron self-arm + output contract).

Key implementation notes:
- `gh issue view --json` doesn't include `body` reliably across all `gh` versions — verify with `gh --version >=2.40`. Add a version check at Phase 1.
- Branch-name derivation function lives in a Bash snippet in the SKILL body so it's deterministic and grep-able.

### Skill 3 — `ship-epic-gh`

Input: **`<owner>/<repo>#<n>`** — a parent issue with a managed `## Sub-issues` task-list section.

Phase 0 — parse parent body:
- `gh issue view <n> --repo <owner>/<repo> --json body,labels,state`
- Extract the `<!-- ship-epic:sub-issues:start -->` ... `<!-- ship-epic:sub-issues:end -->` block.
- Parse each `- [ ] #N — <title>` or `- [ ] owner/repo#N — <title>` line.
- Resolve to (owner, repo, number) tuples.

Phase 1 — build dependency DAG:
- For each sub-issue: `gh issue view <num> --repo <owner>/<repo> --json labels`
- Filter labels matching `^blocks:#?(\d+|[\w-]+/[\w-]+#\d+)$` or `^blocked-by:#?(\d+|[\w-]+/[\w-]+#\d+)$`.
- Build directed graph; DFS for cycles (same algorithm as Linear sibling).

Phase 2 — state classification per sub-issue: derive via the same shared state-map (label + state + state_reason).

Phase 3+ — coordination logic: **unchanged from Linear sibling.** Spawn `/loop 6m /abc:ship-issue-gh <owner>/<repo>#<n>` per ready sub-issue. Gate blocked ones. Aggregate status to parent.

Phase 4 status aggregation: update parent body's `## Sub-issues` section (toggling `[ ]` → `[x]` happens automatically when child closes — we don't need to write it, but we WILL append a snapshot comment per epic-wake for audit trail).

## Files to create

```
plugins/abc/skills/
├── scaffold-sub-issues-gh/
│   ├── SKILL.md                    (~250 lines)
│   └── github-conventions.md       (~80 lines — label scheme, task-list parsing rules)
├── ship-issue-gh/
│   ├── SKILL.md                    (~380 lines, mirrors ship-issue with GitHub-mode rewrites)
│   ├── DESIGN.md                   (~270 lines, mirrors ship-issue DESIGN)
│   └── README.md                   (~240 lines, mirrors ship-issue README)
└── ship-epic-gh/
    ├── SKILL.md                    (~200 lines, mirrors ship-epic with task-list-based hierarchy)
    └── DESIGN.md                   (~140 lines, mirrors ship-epic DESIGN)
```

**Additional edits:**

- `plugins/abc/.claude-plugin/plugin.json` — bump version `0.4.0` → `0.5.0`, update description string to include the three new skills.
- `.claude-plugin/marketplace.json` — same.
- `README.md` (top-level) — extend the lifecycle diagram to show the GitHub branch, add three new rows to the Skills table.

### Allowed-tools delta (per new skill)

Mostly the same as Linear siblings, with:
- **Removed** (no Linear MCP): `mcp__claude_ai_Linear__*`
- **Added**: `Bash(gh issue:*)`, `Bash(gh label:*)`, `Bash(gh repo:*)`, `Bash(gh api:*)` (already in ship-issue's tools), `Bash(gh project:*)` (only if future Projects V2 integration), `Bash(gh pr:*)` (already there).

## Existing-code reuse

These skills do **not** reuse code at the file level (skills are independent), but the following design pieces from the Linear siblings are lifted verbatim:

- Phase 0.5 self-arm logic and cron-entry match rule (`ship-issue/SKILL.md` lines 101–120) — identical.
- Phase 1 plan parsing (strict + loose formats) in `scaffold-sub-issues/SKILL.md` — identical, lifted.
- Phase 1.5 multi-plan reconciliation — identical.
- Phase 3 state-table structure (rows 1–6) — same structure, only the state-derivation rules in each row change.
- Phase 4 fixing handler's three-strikes counter — uses comment markers, which work identically.
- DFS cycle detection in ship-epic — algorithm identical.

## Verification

After implementation, run these end-to-end checks:

1. **Single-repo smoke test.**
   - Create a throwaway repo (or use a personal sandbox like `luistorres/scratch`).
   - Write a tiny `PLAN-test.md` with 2 sub-tasks, one with `blocked-by: ST-1`.
   - Run `/abc:scaffold-sub-issues-gh PLAN-test.md`.
   - Confirm: parent created, 2 sub-issues created, `status:*` + `repo:*` labels exist, task-list in parent body matches, `blocks:#N` label on the dependent sub-issue.
   - Manually close the leading sub-issue; verify the task-list checkbox auto-updates to `[x]`.
2. **Existing-parent mode.**
   - Take any existing GitHub issue, pass as `<owner>/<repo>#<n>` to `/abc:scaffold-sub-issues-gh`. Confirm it appends sub-issues into the parent's body and warns about ordering.
3. **State machine round-trip.**
   - Run `/abc:ship-issue-gh <owner>/<repo>#<n>` on the parent → confirm it walks the 2 sub-issues serially.
   - At each transition, verify the issue's label set in GitHub UI matches the expected state.
   - Force a `blocked-user` case (e.g. add a scope-creep comment) → confirm the skill halts without closing the issue and writes the right marker comment.
4. **Three-strikes counter.**
   - Push a deliberately-failing test commit 3 times. Confirm the failcount markers accumulate to `=3` and the skill transitions to `failed` on the third with `status:closed`, `stateReason=not_planned`.
5. **Cross-repo smoke test.** (Optional, only if user has 2 repos.)
   - Author a plan with sub-tasks in two different repos.
   - Run `scaffold-sub-issues-gh` → confirm parent in hub repo, sub-issues distributed via `owner/repo#N` links in task-list, autolinks resolve correctly in GitHub UI.
   - Run `ship-epic-gh` → confirm DAG built from cross-repo `blocked-by:` labels, workers spawn per-sub-issue with correct `--repo` flag.
6. **`## Validation` gate.**
   - Mark one sub-issue's description with a `## Validation` section. Drive it through ship-issue-gh. After merge, confirm it transitions to `blocked-verify` and stays open (not closed), with inlined validation steps in a comment.
7. **Self-cancel.**
   - When all sub-issues reach `merged`, confirm both the epic-level cron AND the per-worker crons self-cancel via `CronDelete`.

## Open items / deferred

- **Projects V2 status field as a richer alternative to labels.** Skipped for v1. If labels become noisy at scale, a follow-up MR can add `--use-project <number>` flag to `ship-issue-gh` to drive status via Projects V2 instead. Label-based stays the default.
- **`gh issue develop` integration.** Optional in v1 — branch is derived locally. v2 could call `gh issue develop --name <derived>` to formally link the branch to the issue in GitHub UI.
- **Cross-host support** (GitHub Enterprise + github.com in same plan). v1 assumes one host per invocation. Add a `--host` resolution step in v2 if needed.
- **Native sub-issues API.** If GitHub ships Issue-level sub-issue endpoints later, replace the task-list-in-body pattern with native calls (simpler, native UI gets richer). The skill's interface doesn't change.
- **Migration from Linear to GitHub for an in-flight epic.** Not supported — users do this manually by re-running `scaffold-sub-issues-gh` against a new plan file.

## Risks / sharp edges

- **`gh` version sensitivity.** `--json body` is reliable from v2.40+. The skills will check `gh --version` at Phase 1 and halt with a clear upgrade message if older.
- **Marker comments mid-body.** If the user manually edits the parent body's `## Sub-issues` section (e.g. reorders), the skill respects whatever's between the fence markers on next read. If they delete the markers, the skill re-injects them at the end of the body on next epic-wake.
- **Label proliferation.** With many sub-issues, `blocks:#N` / `blocked-by:#N` labels accumulate. Acceptable trade for not having native relations; revisit if labels become unmanageable.
- **Closed sub-issues in task-list.** GitHub renders closed-issue links with a strikethrough automatically — no skill action needed. But `gh api` doesn't return `state` for closed issues without `state=all` filter — the skill must pass `--state all` everywhere it lists.
