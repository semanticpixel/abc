---
name: review-epic-gh
description: GitHub · Review-only counterpart to /abc:ship-epic-gh. Self-arming /loop that watches a GitHub parent issue's managed `## Sub-issues` task-list, reviews each child PR as it surfaces against the FULL epic context (parent spec + merged-sibling decisions + pending children's criteria), posts inline + spec-cross-referenced summary comments via the abc:reviewer subagent, and exits when the epic closes. Never merges. TRIGGER when the user says "/abc:review-epic-gh <owner>/<repo>#<n>", asks to "review this epic as it ships", or wants a standing reviewer session running parallel to /abc:ship-epic-gh.
argument-hint: "<owner>/<repo>#<n> [--no-compact]"
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
  - Bash(gh auth status:*)
  - Bash(gh issue view:*)
  - Bash(gh issue list:*)
  - Bash(gh pr view:*)
  - Bash(gh pr list:*)
  - Bash(gh pr diff:*)
  - Bash(gh pr comment:*)
  - Bash(gh api:*)
---

# /abc:review-epic-gh — epic-context PR reviewer (GitHub)

Watch a GitHub **parent issue** with a managed `## Sub-issues` task-list and review each child PR **against the full epic context** — the parent spec, the design decisions already taken in merged sibling PRs, and the acceptance criteria of children still pending. This is the reviewer half of the two-session epic-shipping pattern: `/abc:ship-epic-gh` (or `/abc:ship-issue-gh` on the parent) implements in one session; this skill reviews in another, holding the *top-down* spec context the per-PR view can't see.

**Review-only.** This skill never merges, never pushes, never closes issues, never edits issue bodies. Its only writes are PR review comments and its own dedup markers.

The label scheme, task-list fence, and marker conventions are documented in [`../scaffold-sub-issues-gh/github-conventions.md`](../scaffold-sub-issues-gh/github-conventions.md) (re-exported locally as [`./github-conventions.md`](./github-conventions.md)).

## Hard rules

- **Never merge, approve-with-merge, push, close, or label.** Posting review comments and `<!-- review-epic:* -->` markers is the entire write surface.
- **Never review a PR twice at the same HEAD SHA.** The dedup marker (Phase 2) is load-bearing — without it every tick re-reviews everything.
- **Never edit content inside the parent's `<!-- ship-epic:sub-issues:start/end -->` fence** — or anywhere else in the parent body. The shipping skills own it.
- **Do not run this skill in the same Claude Code session as `ship-issue-gh` / `ship-epic-gh` workers.** The dual-context perspective is the whole point: the implementer session holds per-PR context, this session holds the epic-wide spec. One session holding both collapses the benefit (and bloats context twice as fast).
- **Always self-cancel the cron on termination** (Phase 5), mirroring the `ship-*` family contract.

## Phase 0: Parse input and self-arm

### Normalize the arg

**Flag extraction (before shape detection):** detect and strip a trailing `--no-compact` flag from `$ARGUMENTS`. When present, set no-compact mode for this invocation — the compact-between-reviews prompt (Phase 4) is skipped. The flag stays in the **raw arg string** used for cron arming/matching, so the opt-out survives every subsequent tick. Contract: [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md).

`$ARGUMENTS` is one of:

1. **`<owner>/<repo>#<n>`** — a GitHub parent issue ID.
2. **GitHub issue URL** (`https://github.com/<owner>/<repo>/issues/<n>`, optionally Enterprise host) → extract `<owner>/<repo>#<n>`.

Anything else (Linear IDs, bare `#<n>`, milestone refs, comma-lists) → reject with the two supported shapes. This skill requires an explicit GitHub parent issue.

**Auth pre-flight.** `gh auth status --hostname <host>`. If not authed → halt with the auth command.

### Fetch parent and validate

1. `gh issue view <n> --repo <owner>/<repo> --json number,title,state,stateReason,labels,body`.
2. If `state=closed` → the epic is already done. Print a one-line "epic closed — nothing to review" summary and exit **without arming a loop**.
3. Locate the `<!-- ship-epic:sub-issues:start/end -->` fence. If missing → reject: "Parent has no managed `## Sub-issues` task-list. Run `/abc:scaffold-sub-issues-gh` first." Parse the `- [ ] / - [x] <ref>` entries to fully-qualified child IDs (same parse rule as `ship-epic-gh` Phase 0).

### Self-arm the loop

Mirror `ship-epic-gh`'s cron-entry match rule with this skill's name:

> A `CronList` entry **matches** when its command string contains `<command-name> <raw-arg>` followed by a word boundary — the next character (if any) must NOT be alphanumeric, `-`, `,`, `/`, or `#`. `<command-name>` is the literal slash-command name Claude Code injects (e.g. `/abc:review-epic-gh` via plugin namespace) — read it from the `<command-name>` tag, never hardcode. Fallback regex: `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?review-epic-gh <raw-arg>(?![A-Za-z0-9_,/#-])`.

- Match found → no-op (the common loop-tick path), proceed to Phase 1.
- No match → `Skill(skill: "loop", args: "12m <command-name> <raw-arg>")`, then proceed to Phase 1 — the first tick also does the first iteration's work.

12-minute cadence sits in the ~10–15 min target: slower than the 6m workers (a review is only actionable once a PR exists or gains commits), fast enough that a worker's `pr-open` window usually gets its review before the human merges.

## Phase 1: Bootstrap context (per tick, ≤30KB)

Load fresh each tick (the tick interval keeps the prompt cache warm; re-fetching also picks up mid-epic spec edits):

1. **Parent issue body verbatim** — the source of truth.
2. **Per child** (from the task-list): title, state, dependency labels (`blocks:*` / `blocked-by:*`), and the **acceptance-criteria section** of its body — a `## Acceptance criteria` heading or an `- **acceptance:**` block, whichever convention the scaffold used. Skip scope / out-of-scope prose unless a review needs it.

   **Dedup against the parent (load-bearing for the budget).** Scaffolded child bodies are usually verbatim ST-sections of the parent PLAN — measured on the `semanticpixel/carn#2` fixture, the parent body is ~29.7KB and the 11 child bodies are another ~29.3KB of near-pure duplication; naive assembly doubles the budget. When a child's spec text already appears in the parent body, do **not** re-include it — cite its location ("ST-4 section of the parent"). Include a child's own body only where it diverges from the parent's section (edited mid-epic).
3. **Merged sibling PRs**: per PR, the summary review comment this skill previously posted (if any) plus a **diffstat** (`gh pr diff <n> --stat`). Full diffs of merged siblings only when a current review needs to check a specific decision.
4. **Pending children's acceptance criteria** — the forward-compat lens: what will later sub-issues exercise? (Subject to the same parent-dedup rule.)

**Budget: keep the assembled context under ~30KB.** With parent-dedup, the carn#2 fixture lands at ~30KB (the parent body alone). When over, trim in this order: (1) merged-sibling full diffs → diffstat only, (2) merged-sibling diffstats → PR title + summary-comment only, (3) pending children's criteria → titles only. Never trim the parent body or the under-review child's acceptance criteria.

## Phase 2: Enumerate review targets (dedup)

1. List candidate PRs: for each **open** child, `closedByPullRequestsReferences` plus `gh pr list --repo <owner>/<repo> --state open --json number,headRefName,headRefOid,url` filtered to branches matching `<child-n>-*`.
2. For each candidate PR, read its HEAD SHA (`headRefOid`) and fetch its top-level comments (`gh api /repos/<owner>/<repo>/issues/<pr>/comments`). If a `<!-- review-epic:reviewed-at:<sha> -->` marker matching the **current** HEAD SHA exists → **skip this PR with no further API calls**. This dedup check is the only cost for unchanged PRs.
3. A PR whose markers all reference older SHAs has new commits → it's a review target (the stale marker stays; history is the audit trail).

No targets this tick → print the one-line no-op summary (Phase 6) and return.

## Phase 3: Review each target

For each target PR, in task-list order:

1. Fetch the diff: `gh pr diff <n> --repo <owner>/<repo>`.
2. Spawn the existing **`abc:reviewer`** subagent (`Agent` tool, `subagent_type: reviewer`) — do **not** edit `agents/reviewer.md`; extend its input via the prompt. Pass:
   - The unified diff (its standard input contract), plus
   - **Cross-cutting epic context** from Phase 1: the parent spec, this child's acceptance criteria **verbatim with their sub-issue ID**, merged-sibling decisions, and pending children's criteria — with the instruction to additionally evaluate (a) which acceptance bullets this diff satisfies/misses, citing them **by sub-issue ID and bullet**, and (b) forward-looking flags where a pending sub-issue will exercise this code differently.
3. Post the review in one `gh api` call: `POST /repos/<owner>/<repo>/pulls/<pr>/reviews` with `event: COMMENT`, the reviewer's inline comments as the `comments` array, and a **summary body** with explicit structure:
   - **(a) Inline comments** — one-line index of what was flagged.
   - **(b) Spec cross-reference** — "satisfies ST-N bullet X … misses ST-N bullet Y", citing specific acceptance bullets by sub-issue ID, never free-text paraphrase.
   - **(c) Forward-looking flags** — "ST-N+1 will exercise this path differently; current shape will need rework", citing the pending child.
4. Drop the dedup marker as a **marker-only** top-level PR comment (the marker is the entire body, matching the `<!-- ship-issue:* -->` marker-only convention): `gh pr comment <n> --repo <owner>/<repo> --body '<!-- review-epic:reviewed-at:<sha> -->'` where `<sha>` is the HEAD SHA the review was produced against.
5. **Compact-between-reviews boundary** — see Phase 4 before starting the next target.

## Phase 4: Compact between reviews

Consumer of [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md) at the **"between two PR reviews"** boundary: after a review pass completes (marker dropped) and **one or more un-reviewed targets remain in this tick's queue**, print — as the last output of the tick —

```
🗜 Review of <pr-url> posted. Run /compact now to free context before reviewing <next-pr-url>.
```

then **end the tick** (same end-the-wake rule as the workers — the dedup markers persist on the PRs, so the next tick's Phase 2 picks up exactly the remaining targets). Skip in no-compact mode, and when the just-reviewed PR was the only/last target. At most once per tick.

## Phase 5: Termination

On every tick, before Phase 1, re-check the parent:

- **Parent `state=closed`** (any reason) or carrying a `status:done` label → terminal. Print a summary of all PRs reviewed by this loop (scan for this skill's `<!-- review-epic:reviewed-at:* -->` markers across the children's PRs) with thread links, `CronDelete` the loop's own cron entry via the Phase 0 match rule, and exit cleanly. This lands within one tick of the parent closing.
- User-invoked `Ctrl-C` / loop cancellation needs no cleanup — every tick re-derives from GitHub; markers already posted keep dedup correct on any future re-arm.

If `CronDelete` fails, print a note ("couldn't auto-cancel; run /loop cancel") and continue — the summary is the authoritative surface.

## Phase 6: Output contract (every tick)

```
/review-epic-gh tick <timestamp>
Parent: <owner>/<repo>#<n>  "<title>"  (open, 3 of 6 children merged)

  [reviewed]   PR #43 (child #39)  5 inline, 2 spec-refs, 1 forward flag
  [skipped]    PR #44 (child #40)  marker matches HEAD abc1234
  [no-pr-yet]  child #41, #42

Next tick: /loop 12m /abc:review-epic-gh <raw-arg>
```

One line on no-op ticks: `no-op tick — no new commits on any child PR`.

## Notes on persistence

Stateless across sessions — GitHub is the source of truth. The `<!-- review-epic:reviewed-at:<sha> -->` markers on the PRs are the entire dedup store; closing the terminal mid-loop is safe, and a force-push that discards a marker simply triggers a benign re-review. Append markers, never edit them.
