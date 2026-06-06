# Linear conventions for /abc:review-epic

How the Linear data model maps onto the conventions the `-gh` family documents in [`../scaffold-sub-issues-gh/github-conventions.md`](../scaffold-sub-issues-gh/github-conventions.md). Linear-side structure is native — no fence, no `status:*` label emulation — so this file is the mapping table, not a second conventions doc.

## Data-model mapping

| Concept | GitHub family | Linear family (this skill) |
|---|---|---|
| Parent → children | Managed `<!-- ship-epic:sub-issues:start/end -->` task-list fence in the parent body | Native sub-issues: `list_issues` with `parentId` |
| Child terminal state | `state=closed` + `stateReason` | `statusType` (`completed` = Done, `canceled`) |
| Dependencies | `blocks:#N` / `blocked-by:#N` labels | Native `blocks` / `blocked by` relations |
| Repo routing | Issue lives in the repo | `repo:<name>` label → `<cwd>/<name>/` workdir → platform from `git remote get-url origin` (same convention as `ship-issue` Phase 1) |
| PR branch | Derived `<n>-<kebab-title>` | Linear's `gitBranchName` field on the issue |
| Review surface | GitHub PR | GitHub PR **or** GitLab MR, per the child's resolved platform |

## Marker placement (load-bearing)

All `<!-- review-epic:* -->` markers are posted **on the PR/MR, never on the Linear issue**:

| Marker | Posted on | Meaning |
|---|---|---|
| `<!-- review-epic:reviewed-at:<sha> -->` | child PR/MR (top-level comment, marker-only body) | This loop reviewed the PR/MR at HEAD `<sha>`; skip until a new commit lands |

This is the same marker namespace `review-epic-gh` owns — placement on the PR/MR (rather than the tracker) is what makes the dedup convention platform-agnostic: both variants read and write the identical marker in the identical place, so review history survives a tracker migration and the two skills can never double-review the same HEAD.
