---
name: review-epic
description: Linear · Review-only counterpart to /abc:ship-epic. Self-arming /loop that watches a Linear parent issue's sub-issues, reviews each child's PR/MR (GitHub or GitLab, routed via the `repo:` label) as it surfaces against the FULL epic context (parent spec + merged-sibling decisions + pending children's criteria), posts inline + spec-cross-referenced summary comments via the abc:reviewer subagent, and exits when the parent reaches Done. Never merges. TRIGGER when the user says "/abc:review-epic PARENT-ID", asks to "review this epic as it ships" against a Linear parent, or wants a standing reviewer session running parallel to /abc:ship-epic.
argument-hint: "PARENT-ID | https://linear.app/.../PARENT-ID [--no-compact]"
model: opus
allowed-tools:
  - Skill
  - CronList
  - CronDelete
  - Agent
  - Read
  - Grep
  - Glob
  - AskUserQuestion
  - Bash(pwd:*)
  - Bash(ls:*)
  - Bash(git remote:*)
  - Bash(gh auth status:*)
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh pr diff:*)
  - Bash(gh pr comment:*)
  - Bash(gh api:*)
  - Bash(glab auth status:*)
  - Bash(glab mr view:*)
  - Bash(glab mr list:*)
  - Bash(glab mr diff:*)
  - Bash(glab mr note:*)
  - Bash(glab api:*)
  - mcp__claude_ai_Linear__get_issue
  - mcp__claude_ai_Linear__list_issues
---

# /abc:review-epic — epic-context PR/MR reviewer (Linear)

Watch a Linear **parent issue** with sub-issues and review each child's PR/MR **against the full epic context** — the parent spec, the design decisions already taken in merged sibling PRs, and the acceptance criteria of children still pending. This is the reviewer half of the two-session epic-shipping pattern: `/abc:ship-epic` (or `/abc:ship-issue` on the parent) implements in one session; this skill reviews in another, holding the *top-down* spec context the per-PR view can't see.

**Review-only.** This skill never merges, never pushes, never closes issues, never transitions Linear states. Its only writes are PR/MR review comments and its own dedup markers — and those live **on the PR/MR, never on the Linear issue** (see [`./linear-conventions.md`](./linear-conventions.md)), so the dedup convention is byte-identical with [`../review-epic-gh/SKILL.md`](../review-epic-gh/SKILL.md).

The per-PR review logic is shared with the GitHub variant via the `abc:reviewer` subagent; what differs here is plumbing — Linear MCP resolution, per-child platform routing, and the GitLab posting path. Linear↔VCS mapping lives in [`./linear-conventions.md`](./linear-conventions.md).

## Hard rules

- **Never merge, approve-with-merge, push, close, label, or transition Linear state.** Posting PR/MR review comments and `<!-- review-epic:* -->` markers is the entire write surface. No Linear write tools are granted — by construction.
- **Never review a PR/MR twice at the same HEAD SHA.** The dedup marker (Phase 2) is load-bearing — without it every tick re-reviews everything.
- **Never post markers on the Linear issue.** Markers live on the PR/MR so dedup is platform-agnostic and shared with `review-epic-gh` — a future migration of an epic between trackers keeps its review history.
- **Do not run this skill in the same Claude Code session as `ship-issue` / `ship-epic` workers.** The dual-context perspective is the whole point: the implementer session holds per-PR context, this session holds the epic-wide spec. One session holding both collapses the benefit (and bloats context twice as fast).
- **Always self-cancel the cron on termination** (Phase 5), mirroring the `ship-*` family contract.
- **One-time post gate, then unattended-by-design.** The repo convention gates posting reviewer comments behind `AskUserQuestion`; a walk-away loop can't ask every tick. Reconciliation: the **first review pass of an invocation** is confirmed via `AskUserQuestion` (Phase 3 step 3); on approval, that consent covers all subsequent posts for the life of the loop. Declining halts the loop. A session restart re-asks once — the gate is per-invocation, not persisted.

## Phase 0: Parse input and self-arm

### Normalize the arg

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-between-reviews prompt (Phase 4) is skipped. The flag stays in the **raw arg string** used for cron arming/matching, so the opt-out survives every subsequent tick. Contract: [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

`$ARGUMENTS` is one of:

1. **Bare Linear ID** (e.g. `PROJ-100`) — the parent issue.
2. **Linear issue URL** (`https://linear.app/<org>/issue/<id>`) → strip prefix, extract `TEAM-N`.

Anything else (GitHub `<owner>/<repo>#<n>` refs, comma-lists, `milestone:` refs, project URLs) → reject with the two supported shapes. This skill requires an explicit Linear parent issue; GitHub parents go through `/abc:review-epic-gh`.

### Fetch parent and validate

1. `mcp__claude_ai_Linear__get_issue` with `id: PARENT-ID`, `includeRelations: true`. Read description, labels, `statusType`.
2. If `statusType` is `completed` (Done) or `canceled` → the epic is done, but **how to exit depends on whether a cron is armed**. Run the cron-entry match rule (below): if a matching entry **exists** (this is a loop tick), terminate via Phase 5 — emit the reviewed-PRs summary and `CronDelete` the entry — so the loop self-cancels instead of zombie-firing "epic done" every 12 minutes. Only when **no** matching cron exists (a fresh invocation against an already-done epic) print a one-line "epic done — nothing to review" and exit without arming.
3. Resolve sub-issues: `mcp__claude_ai_Linear__list_issues` with `parentId: PARENT-ID`, no status filter — Linear's native parent/child relation replaces the `-gh` family's managed task-list fence. If the list is empty → reject: "PARENT-ID has no sub-issues. Run `/abc:scaffold-sub-issues` first."

**If any of these reads fail** (MCP error, timeout) → halt with the error verbatim; an unknown epic state is not "nothing to review."

### Self-arm the loop

Mirror `ship-epic`'s cron-entry match rule with this skill's name:

> A `CronList` entry **matches** when its command string contains `<command-name> <raw-arg>` followed by a word boundary — the next character (if any) must NOT be alphanumeric, `-`, or `,`. `<command-name>` is the literal slash-command name Claude Code injects (e.g. `/abc:review-epic` via plugin namespace) — read it from the `<command-name>` tag, never hardcode. Fallback regex: `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?review-epic <raw-arg>(?![A-Za-z0-9_,-])`.
>
> Note this skill's name is a **prefix of `review-epic-gh`** — the required space between `<command-name>` and `<raw-arg>` is what disambiguates: an entry for `/abc:review-epic-gh <owner>/<repo>#<n>` never contains `review-epic ` followed by a Linear ID, so cross-matching is impossible.

- Match found → no-op (the common loop-tick path), proceed to Phase 1.
- No match → `Skill(skill: "loop", args: "12m <command-name> <raw-arg>")`, then proceed to Phase 1 — the first tick also does the first iteration's work.

12-minute cadence sits in the ~10–15 min target: slower than the 6m workers (a review is only actionable once a PR exists or gains commits), fast enough that a worker's `pr-open` window usually gets its review before the human merges.

## Phase 0.7: Resolve platform per child (repo routing)

For each **open** sub-issue, resolve where its PR/MR lives — same `repo:` label convention as `ship-issue` Phase 1:

1. Collect label names starting with `repo:`. Exactly one expected; `0` → skip the child this tick with a `[no-repo-label]` line in the output; `2+` → same skip, noting the ambiguity.
2. Extract `<name>` from `repo:<name>` → workdir is the `<cwd>/<name>/` subdirectory. Missing subdir → skip with a `[no-workdir]` line.
3. Detect the platform from `git -C <workdir> remote get-url origin`: contains `github.com` → `gh`; contains `gitlab.<host>` → `glab`; anything else → skip with `[unknown-platform]`.
4. Confirm CLI auth (`gh auth status` / `glab auth status`) once per platform per tick. Not authed → halt with the auth command — a reviewer that can read but not post would burn the dedup-free review work every tick.

Skipped children are **not** errors — this skill is review-only, so it degrades by narrowing coverage and saying so, rather than halting the whole loop the way a worker must. Cache the `{workdir, platform, cli}` tuple per child for this tick; re-resolve fresh next tick.

## Phase 1: Bootstrap context (per tick, ≤30KB)

Load fresh each tick (the tick interval keeps the prompt cache warm; re-fetching also picks up mid-epic spec edits):

1. **Parent issue description verbatim** — the source of truth.
2. **Per child** (from the `parentId` listing): title, `statusType`, dependency relations (`blocks` / `blocked by` from `includeRelations`), and the **acceptance-criteria section** of its description — a `## Acceptance criteria` heading or an `- **acceptance:**` block, whichever convention the scaffold used. Skip scope / out-of-scope prose unless a review needs it.

   **Dedup against the parent (load-bearing for the budget).** Scaffolded child descriptions are usually verbatim ST-sections of the parent PLAN, so naive parent+children assembly roughly **doubles** the spec bytes. When a child's spec text already appears in the parent description, do **not** re-include it — cite its location ("ST-4 section of the parent"). Include a child's own description only where it diverges from the parent's section (edited mid-epic). Same rule and reference measurement as `review-epic-gh` Phase 1.
3. **Merged sibling PRs/MRs**: per PR/MR, the summary review comment this skill previously posted (if any) plus a **per-file change summary**: GitHub — `gh api /repos/<owner>/<repo>/pulls/<n>/files --jq '.[] | "\(.filename) +\(.additions) -\(.deletions)"'` (`gh pr diff` has no `--stat`); GitLab — `glab api "projects/:id/merge_requests/<iid>/diffs" --paginate` for the file list (`new_path` per entry; the API doesn't expose per-file +/− counts — fall back to `glab mr diff <iid>` only when a review needs a specific decision).
4. **Pending children's acceptance criteria** — the forward-compat lens: what will later sub-issues exercise? (Subject to the same parent-dedup rule.)

**Budget: keep the assembled context under ~30KB.** When over, trim in this order: (1) merged-sibling full diffs → per-file change summary only, (2) per-file summaries → PR title + summary-comment only, (3) pending children's criteria → titles only. Never trim the parent description or the under-review child's acceptance criteria.

## Phase 2: Enumerate review targets (dedup)

1. List candidate PRs/MRs: for each **open** child that survived Phase 0.7, take the child's `gitBranchName` (Linear provides this on the issue object) and the issue's attachments/links, then: GitHub — `gh pr list --repo <owner>/<repo> --state open --head <gitBranchName> --json number,headRefOid,url`; GitLab — `glab mr list --source-branch <gitBranchName> --output json`.
2. For each candidate, read its HEAD SHA (GitHub: `headRefOid`; GitLab: `diff_refs.head_sha` from `glab mr view <iid> --output json`) and fetch its top-level comments (GitHub: `gh api /repos/<owner>/<repo>/issues/<pr>/comments`; GitLab: `glab api "projects/:id/merge_requests/<iid>/notes" --paginate`). If a `<!-- review-epic:reviewed-at:<sha> -->` marker matching the **current** HEAD SHA exists → **skip this PR/MR with no further API calls**. This dedup check is the only cost for unchanged PRs.
3. A PR/MR whose markers all reference older SHAs has new commits → it's a review target (the stale marker stays; history is the audit trail).

No targets this tick → print the one-line no-op summary (Phase 6) and return.

## Phase 3: Review each target

For each target, in sub-issue order:

1. Fetch the diff: `gh pr diff <n> --repo <owner>/<repo>` or `glab mr diff <iid>`.
2. Spawn the existing **`abc:reviewer`** subagent (`Agent` tool, `subagent_type: reviewer`) — do **not** edit `agents/reviewer.md`; extend its input via the prompt. Pass:
   - The unified diff (its standard input contract), plus
   - **Cross-cutting epic context** from Phase 1: the parent spec, this child's acceptance criteria **verbatim with their sub-issue ID**, merged-sibling decisions, and pending children's criteria — with the instruction to additionally evaluate (a) which acceptance bullets this diff satisfies/misses, citing them **by sub-issue ID and bullet**, and (b) forward-looking flags where a pending sub-issue will exercise this code differently.
3. **One-time post gate** (first review pass of this invocation only): show the assembled review — inline comments plus summary — via `AskUserQuestion` for a single go/no-go. Approval covers this and **every subsequent post** for the life of the loop (see Hard Rules); decline → halt the loop and `CronDelete` via the Phase 0 match rule. Later passes skip this step entirely.
4. Post the review:
   - **GitHub** — one call: `POST /repos/<owner>/<repo>/pulls/<pr>/reviews` with `event: COMMENT`, the reviewer's inline comments as the `comments` array, and the summary as the review body.
   - **GitLab** — no batch review API: post each inline comment as a positioned discussion (`glab api "projects/:id/merge_requests/<iid>/discussions" -f body=<text> -f 'position[...]'` using `diff_refs` from the MR for `base_sha`/`start_sha`/`head_sha`), then the summary as one `glab mr note <iid> --message <body>`.

   The **summary body** has explicit structure either way:
   - **(a) Inline comments** — one-line index of what was flagged.
   - **(b) Spec cross-reference** — "satisfies ST-N bullet X … misses ST-N bullet Y", citing specific acceptance bullets by sub-issue ID, never free-text paraphrase.
   - **(c) Forward-looking flags** — "ST-N+1 will exercise this path differently; current shape will need rework", citing the pending child.
5. Drop the dedup marker as a **marker-only** top-level comment on the PR/MR (the marker is the entire body, matching the `<!-- ship-issue:* -->` marker-only convention): `gh pr comment <n> --repo <owner>/<repo> --body '<!-- review-epic:reviewed-at:<sha> -->'` or `glab mr note <iid> --message '<!-- review-epic:reviewed-at:<sha> -->'` where `<sha>` is the HEAD SHA the review was produced against. **Never on the Linear issue.**
6. **Compact-between-reviews boundary** — see Phase 4 before starting the next target.

## Phase 4: Compact between reviews

Consumer of [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md) at the **"between two PR reviews"** boundary: after a review pass completes (marker dropped) and **one or more un-reviewed targets remain in this tick's queue**, print — as the last output of the tick —

```
🗜 Review of <pr-or-mr-url> posted. Run /compact now to free context before reviewing <next-url>.
```

then **end the tick** (same end-the-wake rule as the workers — the dedup markers persist on the PRs/MRs, so the next tick's Phase 2 picks up exactly the remaining targets). Skip in no-compact mode, and when the just-reviewed PR/MR was the only/last target. At most once per tick.

## Phase 5: Termination

On every tick, before Phase 1, re-check the parent:

- **Parent `statusType` is `completed` (Done) or `canceled`** → terminal. Print a summary of all PRs/MRs reviewed by this loop (scan for this skill's `<!-- review-epic:reviewed-at:* -->` markers across the children's PRs/MRs) with thread links, `CronDelete` the loop's own cron entry via the Phase 0 match rule, and exit cleanly. This lands within one tick of the parent transitioning to Done.
- User-invoked `Ctrl-C` / loop cancellation needs no cleanup — every tick re-derives from Linear + the VCS; markers already posted keep dedup correct on any future re-arm.

If `CronDelete` fails, print a note ("couldn't auto-cancel; run /loop cancel") and continue — the summary is the authoritative surface.

## Phase 6: Output contract (every tick)

```
/review-epic tick <timestamp>
Parent: PROJ-100  "<title>"  (open, 3 of 6 children merged)

  [reviewed]        PR #43 (PROJ-103)  5 inline, 2 spec-refs, 1 forward flag
  [skipped]         MR !12 (PROJ-104)  marker matches HEAD abc1234
  [no-pr-yet]       PROJ-105, PROJ-106
  [no-repo-label]   PROJ-107

Next tick: /loop 12m /abc:review-epic <raw-arg>
```

One line on no-op ticks: `no-op tick — no new commits on any child PR/MR`.

## Notes on persistence

Stateless across sessions — Linear and the VCS are the sources of truth. The `<!-- review-epic:reviewed-at:<sha> -->` markers on the PRs/MRs are the entire dedup store; closing the terminal mid-loop is safe, and a force-push that discards a marker simply triggers a benign re-review. Append markers, never edit them. Because the markers live on the PR/MR rather than the tracker, the dedup state is identical regardless of which review-epic variant posted it.
