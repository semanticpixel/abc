---
name: ship-epic-gh
description: GitHub · GitHub-Issues sibling of /abc:ship-epic. Coordinator for a GitHub parent issue whose children live in a managed `## Sub-issues` task-list. Builds a dependency graph from `blocks:#N` / `blocked-by:#N` labels on the children, fires `/loop 6m /abc:ship-issue-gh <owner>/<repo>#<n>` per ready child (truly parallel via independent cron entries), gates blocked children until upstreams merge, aggregates status into the parent. Self-arms its own `/loop` — invoke once and walk away. TRIGGER when the user says "/ship-epic-gh <owner>/<repo>#<n>", asks to "ship this epic" against a GitHub parent, or wants to drive a multi-repo GitHub epic through merge in parallel.
argument-hint: "<owner>/<repo>#<n>"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Read
  - AskUserQuestion
  - Bash(pwd:*)
  - Bash(ls:*)
  - Bash(gh auth status:*)
  - Bash(gh issue view:*)
  - Bash(gh issue comment:*)
  - Bash(gh issue edit:*)
  - Bash(gh issue close:*)
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh api:*)
---

# /abc:ship-epic-gh — Parallel multi-repo shipping coordinator (GitHub)

Drive a GitHub **parent issue** whose body holds a managed `## Sub-issues` task-list to all-merged by firing one `/loop 6m /abc:ship-issue-gh <owner>/<repo>#<n>` per **ready** child, gating children with unmet `blocked-by:*` labels, and aggregating status on the parent. Each worker (`/abc:ship-issue-gh`) is independent — they run in parallel via their own cron entries, survive session close, and use GitHub Issues as the single source of truth.

This skill is the **coordinator**. It does NOT implement code, open PRs, or run tests directly — those are the workers' jobs.

This is the GitHub-Issues sibling of [`/abc:ship-epic`](../ship-epic/SKILL.md). The two are deliberately parallel skills — pick by tracker, not auto-detect. The label scheme, task-list fence, and marker comments it depends on are documented in [`../scaffold-sub-issues-gh/github-conventions.md`](../scaffold-sub-issues-gh/github-conventions.md).

See [`DESIGN.md`](./DESIGN.md) for the architectural rationale + locked decisions specific to the GitHub case. This file is the operational procedure.

## Hard rules

- **Never** spawn a worker for a child that has an unmet `blocked-by:*` label. Wait for the upstream to reach `merged` first.
- **Never** halt the epic just because one worker hits `blocked-user`. Other workers can continue; the blocked one waits for the human.
- **Never** modify worker state directly (no edits to `<!-- ship-issue:* -->` comments on children). Workers own their own state machines.
- **Never** edit content outside the `<!-- ship-epic:sub-issues:start/end -->` fence in the parent body. User-authored prose stays untouched.
- **Always** self-cancel the epic's cron on terminal states (all merged, any failed). `/abc:ship-issue-gh` self-cancels its own cron per its Phase 7; this skill mirrors that contract at the epic level.
- If the parent has no managed `## Sub-issues` task-list → reject and point the user at `/abc:scaffold-sub-issues-gh` to create one (or `/abc:ship-issue-gh` for a single issue).
- If the dependency graph has a cycle → halt with `blocked-user` and a one-line cycle description. Refuse to start.

## Phase 0: Parse input and self-arm

### Normalize the arg

`$ARGUMENTS` is one of:

1. **`<owner>/<repo>#<n>`** — a GitHub parent issue ID.
2. **GitHub issue URL** (`https://github.com/<owner>/<repo>/issues/<n>`, optionally with Enterprise host) → extract `<owner>/<repo>#<n>`.

Anything else (Linear IDs, bare `#<n>`, milestone refs, comma-lists) → reject. This skill requires an explicit GitHub parent issue. For milestone-style "ship every issue in this collection," use `/abc:ship-issue-gh milestone:<owner>/<repo>/<num>` instead — that's the serial walker; the coordinator pattern needs a real parent for status aggregation.

**Auth pre-flight.** `gh auth status --hostname <host>` where `<host>` is derived from the parent's URL (defaults to `github.com`). If not authed → `blocked-user` with the auth command.

### Fetch parent and parse the task-list

1. `gh issue view <n> --repo <owner>/<repo> --json number,title,state,stateReason,labels,body`.
2. If `state=closed` and `stateReason=completed` → epic is already done. Emit a one-line "already merged" summary and exit (do not arm a loop).
3. Locate the `<!-- ship-epic:sub-issues:start -->` and `<!-- ship-epic:sub-issues:end -->` fence markers in the body. If either is missing → reject with: "Parent `<owner>/<repo>#<n>` has no managed `## Sub-issues` task-list. Run `/abc:scaffold-sub-issues-gh` against this parent first, or use `/abc:ship-issue-gh` for single-issue shipping."
4. Parse each `- [ ] <ref>` and `- [x] <ref>` line between the fences. Each `<ref>` is either `#<n>` (same-repo as parent) or `<owner>/<repo>#<n>` (cross-repo). Normalize to fully-qualified form. The `[x]`-completed entries are kept in the set — they'll be classified `merged` in Phase 2, not skipped at parse time (the worker may still need to be checked for terminal cleanup).

If the parsed child set is empty → reject: "Parent has an empty `## Sub-issues` task-list. Add children with `/abc:scaffold-sub-issues-gh` first."

### Self-arm the loop

Mirror `/abc:ship-issue-gh` Phase 0.5's cron-entry match rule, with the GitHub-ID boundary exclusions:

> A `CronList` entry **matches** this invocation when its command string contains `<command-name> <raw-arg>` **followed by a word boundary** — the next character (if any) must NOT be alphanumeric, `-`, `,`, `/`, or `#`. `<command-name>` is the literal slash-command name Claude Code injects for this invocation (e.g. `/ship-epic-gh` when invoked top-level, or `/<plugin>:ship-epic-gh` when invoked through a plugin namespace — verify from the `<command-name>` tag Claude Code passes at invocation time, including on `/loop`-triggered wakes where the inner command name is still surfaced).
>
> Reading the **actually-injected** name — rather than hardcoding `/ship-epic-gh` — is load-bearing for plugin-namespaced invocations: the hardcoded substring `/ship-epic-gh` is **not** present in `/abc:ship-epic-gh <raw-arg>` (the prefix is `/abc:`, not `/`), so the match always failed and every wake duplicate-armed a new cron.
>
> **Fallback regex** when `<command-name>` isn't reachable (older Claude Code versions, edge cases): test the entry's command string against `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?ship-epic-gh <raw-arg>(?![A-Za-z0-9_,/#-])`. The optional `<plugin>:` prefix capture covers any plugin-namespacing scheme; the trailing negative-lookahead is the same boundary class as the strict rule. The `/` and `#` exclusions are GitHub-ID specific; the Linear sibling's rule doesn't need them.
>
> Boundary check works whether `CronList` reports the wrapped form `/loop 10m <command-name> <raw-arg>` or the inner `<command-name> <raw-arg>`.

- If a matching entry exists → no-op, proceed to Phase 1.
- If no match → invoke `Skill(skill: "loop", args: "10m <command-name> <raw-arg>")` to arm the cron — substituting the **captured `<command-name>`**, not a hardcoded skill name. This is what makes the next wake's match check succeed against this cron entry. Then proceed to Phase 1 — the first wake also does the work of the first iteration.

10-minute cadence is intentional (longer than the 6-minute worker cadence): the coordinator only needs to react when a worker reaches `merged` (unblocks downstream) or terminal (`failed`/`blocked-user`). Both events surface in GitHub within seconds; 10-minute lag is acceptable.

## Phase 1: Build the dependency graph

For each child in the parsed set:

1. `gh issue view <n> --repo <owner>/<repo> --json number,state,stateReason,labels`.
2. Read labels matching `blocks:#<N>` or `blocked-by:#<N>` (same-repo) or `blocks:<owner>/<repo>#<N>` / `blocked-by:<owner>/<repo>#<N>` (cross-repo). Normalize all refs to fully-qualified form for graph nodes.
3. **Filter to in-set edges only.** If a `blocked-by:` label points to an issue NOT in our parsed child set, surface it as `external-blocker` for that child (Phase 2) — don't try to follow it.
4. Build adjacency lists: `blocksMap[id]: Set<id>`, `blockedByMap[id]: Set<id>`. Union both directions so a `blocks:#A` label on B and a `blocked-by:#B` label on A produce the same edge once.

Detect cycles via DFS. On cycle → write `<!-- ship-epic:event:cycle -->` comment on the parent listing the cycle members in order, transition the epic to halt (Phase 5), refuse to fire any workers.

## Phase 2: Classify each child

Pull `CronList` once at the top of this phase — don't re-poll per child. First match wins:

| State | Condition |
|---|---|
| `merged` | `state=closed` AND `stateReason=completed` (worker reached merged terminal — GitHub auto-closes via the PR's `Closes` trailer, plus the worker writes `<!-- ship-issue:event:merged -->`) |
| `failed` | `state=closed` AND `stateReason=not_planned` (worker hit a hard stop) — OR a `<!-- ship-issue:event:failed -->` comment exists |
| `blocked-user` | A `<!-- ship-issue:event:blocked -->` comment exists with no subsequent `<!-- ship-issue:event:resumed -->` — child is still `state=open` |
| `external-blocker` | A `blocked-by:` label points to an issue outside our child set AND that referenced issue is not yet merged |
| `in-flight` | A `CronList` entry matches `/ship-issue-gh <owner>/<repo>#<n>` (worker is already running) |
| `ready` | All in-set `blocked-by:*` upstreams are `merged`, AND no in-flight cron, AND `state=open` (not in any terminal state) |
| `waiting` | One or more in-set `blocked-by:*` upstreams not yet `merged` |

Re-derive fresh on every wake — nothing is persisted locally.

## Phase 3: Fire workers for ready children

For each child in `ready` state:

```
Skill(skill: "loop", args: "6m /abc:ship-issue-gh <owner>/<repo>#<n>")
```

This kicks off the worker's first wake and arms its own cron. The coordinator does NOT wait — it returns and the worker runs independently.

**Do not fire** workers for children already `in-flight` (the worker's own Phase 0.5 cron-match would no-op anyway, but skip explicitly for clarity).

If multiple children are `ready` in the same wake, fire all of them — the workers run in parallel on independent cron entries.

## Phase 4: Aggregate status

### GitHub comment on the parent

Append (not edit) a single `<!-- ship-epic:status -->` comment on the parent with the current snapshot. The task-list checkboxes in the parent body auto-toggle when each child closes — GitHub manages that natively; the skill does not touch the body for this purpose:

```
<!-- ship-epic:status -->
Wake: 2026-05-17T18:30:00Z  (4 of 6 merged)

| State | Child | Latest |
|---|---|---|
| merged | <owner>/repo-a#101 | <PR URL> |
| merged | <owner>/repo-a#102 | <PR URL> |
| in-flight | <owner>/repo-b#103 | pr-open, <PR URL> |
| ready | <owner>/repo-b#104 | → firing worker this wake |
| waiting | <owner>/repo-c#105 | blocked by <owner>/repo-b#104 |
| blocked-user | <owner>/repo-c#106 | awaiting-manual-verification |
```

Use `gh issue comment <parent-n> --repo <owner>/<repo> --body-file <tmpfile>`.

### Terminal block (Phase 8-style output)

```
/abc:ship-epic-gh wake <ts>
Parent: <owner>/<repo>#100  "Add WidgetRow to dashboard"  (4 of 6 merged)

[merged]         <owner>/repo-a#101  <PR URL>
[merged]         <owner>/repo-a#102  <PR URL>
[in-flight]      <owner>/repo-b#103  pr-open <PR URL>
[ready→firing]   <owner>/repo-b#104
[waiting]        <owner>/repo-c#105  blocked by <owner>/repo-b#104
[blocked-user]   <owner>/repo-c#106  awaiting-manual-verification

Next wake: /loop 10m /abc:ship-epic-gh <owner>/<repo>#100
```

Keep terminal output short on no-op wakes (no state changes since last wake): just one line — `no-op wake — 4 of 6 merged, 1 in-flight, 1 blocked-user`.

## Phase 5: Terminal states

### All children `merged`

1. Close the parent: `gh issue close <n> --repo <owner>/<repo> --reason completed`.
2. Write a completion comment: `<!-- ship-epic:event:complete --> ✅ Epic complete: <N> children merged.`
3. `CronDelete` the epic's `/loop` via the cron-entry match rule.
4. Worker loops should already have self-cancelled per `/abc:ship-issue-gh` Phase 7 — if any remain in `CronList`, leave them; they'll wake, derive `merged`, and self-cancel.

### Any child `failed`

1. Write `<!-- ship-epic:event:failed -->` on the parent: `❌ Epic halted: <owner>/<repo>#<n> failed (<reason>). Other children left in their current state.`
2. `CronDelete` the epic's `/loop`.
3. **Also `CronDelete` all in-flight worker `/loop`s for this epic's children.** Identify them via `CronList` + child-ID match. The epic is halted; workers shouldn't keep grinding.
4. Leave the parent issue **open** — failure means a human needs to decide whether to close, redirect, or retry. Do not auto-close the parent on `failed`.
5. Halt.

### Any child `blocked-user` or `external-blocker`

**Do not halt.** Leave the epic loop running — other workers may still be making progress. Surface in the terminal block and status comment, but the loop continues.

### User @-mentions Claude on the parent

Treat as a direct interrupt — read the comment via `gh api /repos/<owner>/<repo>/issues/<n>/comments`, decide whether to halt or adjust. If unclear, write a `blocked-user` comment with reason `user-mention-ambiguous:<comment-id>` and halt.

## Phase 6: Stop

The epic's `/loop` self-cancels on every terminal-state phase via `CronDelete`. The user should not have to run `/loop cancel` manually.

If `CronDelete` fails (entry already gone, job-ID not found), print a note and continue. The GitHub comment is authoritative.

## Notes on edge cases

- **Child added to the parent's task-list mid-flight**: next wake re-fetches the parent body. New entries with `repo:` labels become `ready` (if no `blocked-by:*`) or `waiting` (if blocked). Fired automatically.
- **Child removed from the task-list mid-flight**: if it's `in-flight`, leave its worker running — the worker is on its own contract. Just drop it from the epic's status aggregation.
- **`blocked-by:*` label added mid-flight to an `in-flight` child**: the worker keeps running. The label takes effect for state classification only — future ready/waiting decisions honor it; the current worker is not interrupted.
- **Multiple `/abc:ship-epic-gh` invocations on the same parent**: cron-match deduplicates (idempotent self-arm). Second invocation no-ops.
- **Worker death** (machine reboot, manual `/loop cancel`): next wake sees the worker as no longer `in-flight` but the child issue isn't terminal — re-classifies as `ready` (if blocks satisfied) and fires a new worker. Re-arming is idempotent at the worker level.
- **Cross-repo children with mismatched hosts** (github.com + Enterprise): Phase 0 halts if the parent is on one host and any child ref points to a different host. v1 single-host only.
- **Parent body manually edited mid-flight** (user re-orders the task-list, adds prose between entries): the skill respects whatever is between the fence markers on the next read. If the user accidentally deletes the markers, halt with `blocked-user` and reason `parent-task-list-fence-missing` — don't try to re-inject silently.
