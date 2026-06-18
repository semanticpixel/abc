# GitHub-Issues conventions for the `-gh` skill family

The `-gh` skills (`scaffold-sub-issues-gh`, `ship-issue-gh`, `ship-epic-gh`, `review-epic-gh`) emulate Linear's tracker semantics on top of GitHub Issues. This file documents the label scheme, task-list pattern, and marker comments they all rely on, so behavior stays aligned across the family.

Copy this doc verbatim if you fork or add a new `-gh` skill.

## State-machine emulation (label-based)

GitHub Issues has only `state=open` / `state=closed` plus `state_reason`. We layer Linear-style states on top using labels:

| Linear state | GitHub Issues representation |
|---|---|
| `Backlog` | `state=open`, no `status:*` label |
| `In Progress` | `state=open`, label `status:in-progress` |
| `In Review` | `state=open`, label `status:in-review` |
| `Done` | `state=closed`, `state_reason=completed` |
| `Canceled` | `state=closed`, `state_reason=not_planned` |

**Rules:**

- The `status:*` namespace is reserved for the `-gh` skills. They will create the two labels (`status:in-progress`, `status:in-review`) on first use in a repo, prompting via `AskUserQuestion`.
- `pending` is the **absence** of any `status:*` label on an open issue. No "status:pending" label exists.
- A skill never adds a `status:in-progress` label without removing `status:in-review` (and vice versa). At most one `status:*` label per issue at any time.
- Re-opening a closed issue is out of scope for v1. If the user manually re-opens, the skill treats it as `pending` until a new `status:*` label is applied.

### Suggested label colors

| Label | Color (hex) | Purpose |
|---|---|---|
| `status:in-progress` | `#0e8a16` (green) | Active work |
| `status:in-review` | `#5319e7` (purple) | PR/MR open |
| `repo:*` | `#0366d6` (blue) | Repo routing |
| `blocks:*` | `#d93f0b` (red) | Outgoing dep edge |
| `blocked-by:*` | `#fbca04` (yellow) | Incoming dep edge |

Skills pass `--color` and a short `--description` on first creation; subsequent runs reuse the existing label as-is.

## Hierarchy emulation (task-list-in-body)

We emulate parent → child by maintaining a task-list section in the parent's body. (GitHub *does* have a native sub-issue API as of its 2025 GA, but we deliberately don't depend on it — the task-list-in-body approach keeps the `-gh` family working on GitHub Enterprise instances that haven't enabled it and on older `gh` CLIs, and keeps the hierarchy human-readable in the raw issue body. Portability over native integration.)

```markdown
## Sub-issues
<!-- ship-epic:sub-issues:start -->
- [ ] #42 — Add WidgetRow component to web frontend
- [x] #41 — Bootstrap project
- [ ] otherorg/consumer-app#7 — Adopt v2 tokens
<!-- ship-epic:sub-issues:end -->
```

**Rules:**

- The fence markers (`<!-- ship-epic:sub-issues:start -->` / `<!-- ship-epic:sub-issues:end -->`) are sacred. Skills only edit content **between** them. Anything outside is user-authored and untouched.
- GitHub autolinks `#42` and `<owner>/<repo>#42`, rendering inline title + state. The checkbox auto-toggles to `[x]` when the referenced issue closes — we don't manage that ourselves.
- `ship-epic-gh` walks the list to discover children. Order is the order of the lines in the parent body. New children land at the bottom of the block (append-only) unless the user manually reorders.
- If the fence markers are missing on next read, **`scaffold-sub-issues-gh` re-injects them** at the end of the parent body (it owns parent-body structure). The **coordinators** (`ship-epic-gh`, and `ship-issue-gh` when expanding a parent) do **not** silently re-inject — a parent missing its fence is a structural problem they halt on, so a scaffold/coordinator race or a hand-edited body never gets a second, conflicting block written underneath them. Existing un-fenced task-lists are not migrated automatically either way — too easy to misparse.

### Cross-repo references

- Same-repo: `- [ ] #42 — <title>`
- Cross-repo: `- [ ] <owner>/<repo>#42 — <title>`

The skill detects cross-repo refs via the presence of `/` before `#` and passes `--repo <owner>/<repo>` to all subsequent `gh issue *` calls on that child.

## Dependency expression (for `ship-epic-gh`)

Dependencies between children are expressed as labels on the **child** issues:

- **`blocks:#<N>`** on issue A means "A blocks N" (N can't start until A is merged).
- **`blocked-by:#<N>`** on issue A means "A is blocked by N" (A can't start until N is merged).
- Cross-repo: `blocks:<owner>/<repo>#<N>` / `blocked-by:<owner>/<repo>#<N>`.

**Rules:**

- Both directions are valid — the skill normalizes by reading both label sets and unioning into a DAG.
- DFS cycle detection happens in `ship-epic-gh` Phase 1. Cycles abort the run with a clear error pointing at the cycle members.
- Labels are scoped to the child's own repo. The skill creates them on demand (per-edge) and ignores any pre-existing `blocks:*` / `blocked-by:*` labels that don't match this naming scheme.

## Marker comments (for `ship-issue-gh` state)

`ship-issue-gh` writes durable state via HTML comments inside issue comments. Same pattern as the Linear sibling — they're invisible in the GitHub UI but easy to grep via `gh api .../issues/<n>/comments`.

Every marker below is grep-confirmed against the handler that writes it (see `ship-issue-gh/SKILL.md` / `ship-issue/SKILL.md`). If you add or rename a marker in a skill, update this row in the same change.

| Marker | Meaning |
|---|---|
| `<!-- ship-issue:event:started -->` | Worker began this issue |
| `<!-- ship-issue:event:merged -->` | PR/MR merged, issue ready to close (or transitioning to blocked-verify) |
| `<!-- ship-issue:event:blocked -->` | Halted; needs human (`blocked-user` state) |
| `<!-- ship-issue:event:failed -->` | Hard stop; issue closed `not_planned` |
| `<!-- ship-issue:commit -->` | In the **commit body** of every skill-authored commit (audit signal + "last skill commit" anchor for review-freshness) |
| `<!-- ship-issue:failcount:<key>=N -->` | CI failure counter for three-strikes detection; `<key>` is `github:<check-name>`, `N` the count. Append-only; latest wins |
| `<!-- ship-issue:rebase:auto -->` | Marker-only comment: the branch was auto-rebased onto base and force-pushed after gates passed |
| `<!-- ship-issue:note:reachability -->` | A new UI surface is deliberately orphan; states how a human reaches it during `## Validation` |
| `<!-- ship-issue:note:merge-nudge -->` | Posted when an open PR is green but unmerged, nudging a human to merge (the skill never self-merges) |
| `<!-- ship-issue:verify:passed -->` | Manual `## Validation` confirmed by the user (clears the `blocked-verify` gate); part of the `verify:` sub-namespace |

> No `event:pr-open` marker exists — the `pr-open` state is derived from an open linked PR, not written as a comment. (An earlier version of this table listed it; nothing ever wrote it.) Likewise `event:blocked` is the real marker, not `event:blocked-user`, and the counter is `failcount:<key>=N`, not `check-fail:<name>=<count>`.

The `review-epic:reviewed-at:<sha>` marker (written by `review-epic` / `review-epic-gh` on child PRs) lives in the review-epic family — see `../review-epic-gh/github-conventions.md`.

Comments are append-only — never edit existing comments to mutate state. The latest matching marker wins on re-derivation.

## Argument forms recap

- `<owner>/<repo>` — a repo. Used as the hub or as a target.
- `<owner>/<repo>#<n>` — an issue. Used as a parent ID or a child ref.
- `milestone:<owner>/<repo>/<milestone-name-or-number>` — for `ship-issue-gh` to expand a milestone's open issues into a worker list.

The skills do not accept Linear-style `[A-Z]+-\d+` IDs; pass those to the non-`-gh` siblings instead.
