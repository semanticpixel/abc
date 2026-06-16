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
  - Bash(gh auth status:*)
  - Bash(gh issue view:*)
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
- **Per-tick post gate (conservative by design).** The repo convention gates posting reviewer comments behind `AskUserQuestion`. Each tick re-derives state from GitHub alone and **no consent marker is stored anywhere**, so consent cannot outlive a tick: the gate fires on the **first review pass of each tick that has a review to post** (Phase 3 step 3), and approval covers every post in that tick. Declining halts the loop and self-cancels the cron. No-op ticks never ask. Stated trade-off: a tick holding a pending review **blocks until a human answers** — the reviewer session is walk-away *between* reviews, not *during* them. (The alternative — dropping the gate and posting unattended with an explicit Hard-Rule exception, mirroring how `ship-*` post status comments unattended — was considered and deferred; see the two-session workflow section of the top-level README.)

  **Concurrency while a gate is open.** A blocked `AskUserQuestion` holds the Claude Code turn, and `/loop` runs one turn per session serially — the next 12m cron fire does **not** spawn a second concurrent reviewer process against the same targets. The pending prompt holds the turn until answered; the cron's interim fire is absorbed by the single-session model rather than racing it. So "walk away during a gate" is **non-destructive but stalling**: no double-review, no marker race — the loop simply makes no further progress until the human answers, then resumes from the next tick's fresh Phase 2 derivation (any HEAD that advanced meanwhile is naturally re-targeted). This is why the dedup marker (Phase 2) only needs to guard *posted* reviews, not in-flight ones — there is never more than one in-flight review per session.

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
2. If `state=closed` → the epic is done, but **how to exit depends on whether a cron is armed**. Run the cron-entry match rule (below): if a matching entry **exists** (this is a loop tick), terminate via Phase 5 — emit the reviewed-PRs summary and `CronDelete` the entry — so the loop self-cancels instead of zombie-firing "epic closed" every 12 minutes. Only when **no** matching cron exists (a fresh invocation against an already-closed epic) print a one-line "epic closed — nothing to review" and exit without arming.
3. Locate the `<!-- ship-epic:sub-issues:start/end -->` fence. If missing → reject: "Parent has no managed `## Sub-issues` task-list. Run `/abc:scaffold-sub-issues-gh` first." Parse the `- [ ] / - [x] <ref>` entries to fully-qualified child IDs (same parse rule as `ship-epic-gh` Phase 0).

**If the parent read fails, classify the failure** (an unknown epic state is never treated as "nothing to review"):

- **Permanent** (HTTP 404/410, `Could not resolve to an Issue`, repo-not-found) → the parent is gone. Run Phase 5 termination (emit the reviewed-PRs summary and `CronDelete` the cron) and exit, so a deleted/moved parent doesn't zombie-fire "epic closed" every tick.
- **Transient** (timeout, 5xx, connection reset, auth blip) → halt this tick **without** `CronDelete` and retry next tick. If the same error repeats across consecutive ticks, surface `stalled on same error; run /loop cancel` once so the human can intervene.

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

   **Dedup against the parent (load-bearing for the budget).** Scaffolded child bodies are usually verbatim ST-sections of the parent PLAN, so naive parent+children assembly roughly **doubles** the spec bytes. When a child's spec text already appears in the parent body, do **not** re-include it — cite its location ("ST-4 section of the parent"). Include a child's own body only where it diverges from the parent's section (edited mid-epic). The rule is the invariant; as an illustrative dated measurement (2026-06, `semanticpixel/carn#2`, 11 children): parent ~29.7KB, child bodies another ~29.3KB of near-pure duplication — dedup brings bootstrap to the parent body alone, inside the budget. Re-measure if a different epic becomes the reference fixture.
3. **Merged sibling PRs**: per PR, the summary review comment this skill previously posted (if any) plus a **per-file change summary** from the API: `gh api /repos/<owner>/<repo>/pulls/<n>/files --jq '.[] | "\(.filename) +\(.additions) -\(.deletions)"'` (`gh pr diff` has no `--stat` flag — only `--name-only` and `--patch`). Full diffs (`gh pr diff <n>`) of merged siblings only when a current review needs to check a specific decision.
4. **Pending children's acceptance criteria** — the forward-compat lens: what will later sub-issues exercise? (Subject to the same parent-dedup rule.)

**Budget: keep the assembled context under ~30KB.** When over, trim in this order: (1) merged-sibling full diffs → per-file change summary only, (2) per-file summaries → PR title + summary-comment only, (3) pending children's criteria → titles only. Never trim the parent body or the under-review child's acceptance criteria.

## Phase 2: Enumerate review targets (dedup)

1. List candidate PRs: for each **open** child, `closedByPullRequestsReferences` plus `gh pr list --repo <owner>/<repo> --state open --json number,headRefName,headRefOid,url` filtered to branches matching `<child-n>-*`.

   **0 matches from both sources** — the `<child-n>-*` pattern is the *worker's* branch derivation; a human (or a fix-up branch) may have named the real branch differently, and a PR without a `Closes` trailer never appears in `closedByPullRequestsReferences`. Fall back to the child issue's timeline, **preferring strong "implements" signals over loose mentions** (in priority order):

   1. **`connected` events** — the GitHub Development-panel link (`gh issue develop` / manual "link a pull request"). This is an explicit implements-relation, the strongest fallback signal: `gh api /repos/<owner>/<repo>/issues/<child-n>/timeline --paginate --jq '.[] | select(.event=="connected") | .source.issue.number'` (filter to entries whose `source.issue.pull_request != null`).
   2. **`cross-referenced` events whose head branch contains `<child-n>`** — a loose mention ("see #N", "related to #N") also emits `cross-referenced`, so an unfiltered match can pick an unrelated open PR that merely name-drops the child, post a full epic-context review on it, and burn the `<!-- review-epic:reviewed-at -->` marker there. Resolve each `cross-referenced` PR via `gh pr view <num> --repo <owner>/<repo> --json number,state,headRefOid,url,headRefName` and **keep only those whose `headRefName` contains the child number** as a word-bounded token.

   Only when both tiers miss is the child `[no-pr-yet]`. **Mention-only PRs are deliberately excluded** — a child reachable solely via a loose `cross-referenced` mention (no `connected` link, no `<child-n>` in the branch) is treated as having no PR yet rather than risking a wrong-PR review; if that under-covers a real PR, the developer can add a Development-panel link or a `Closes` trailer to surface it.
   **2+ matches** (branch reuse, closed-and-reopened, multiple linked PRs) — take the first **open** PR and flag the ambiguity in the tick output (e.g. `[reviewed, 2 PRs matched — picked #N]`). Same tiebreaker as the Linear variant's Phase 2.
2. For each candidate PR, read its HEAD SHA (`headRefOid`) and fetch its top-level comments (`gh api /repos/<owner>/<repo>/issues/<pr>/comments`). If a `<!-- review-epic:reviewed-at:<sha> -->` marker matching the **current** HEAD SHA exists → **skip this PR with no further API calls**. This dedup check is the only cost for unchanged PRs.
3. A PR whose markers all reference older SHAs has new commits → it's a review target (the stale marker stays; history is the audit trail).

No targets this tick → print the one-line no-op summary (Phase 6) and return.

## Phase 3: Review each target

For each target PR, in task-list order:

1. **Fetch the diff and pin the reviewed SHA.** `gh pr diff <n> --repo <owner>/<repo>`, and in the same step re-read the PR's current HEAD (`gh pr view <n> --repo <owner>/<repo> --json headRefOid -q .headRefOid`). If it differs from the `headRefOid` Phase 2 selected this target on, the branch advanced mid-tick → **abort this target's pass with `[head-moved]`, drop no marker**, and let the next tick re-derive against the new HEAD. Otherwise pin `<reviewed-sha>` to that value — it flows through the review POST's `commit_id` and is the SHA written in the step-5 dedup marker, so the marker can never claim a SHA the review wasn't produced against.
2. Spawn the existing **`abc:reviewer`** subagent (`Agent` tool, `subagent_type: abc:reviewer` — plugin agents register namespaced; the bare `reviewer` does not resolve in a live session) — do **not** edit `agents/reviewer.md`; extend its input via the prompt. Pass:
   - The unified diff (its standard input contract), plus
   - **Platform + PR ref** — `github`, `<owner>/<repo>`, PR `#<n>`, and the reviewed SHA — so findings cite the concrete target.
   - **The repo's review rules** — the contents of `<workdir>/.claude/review-rules.md` when present, fetched via `gh api /repos/<owner>/<repo>/contents/.claude/review-rules.md?ref=<reviewed-sha>` (this session may hold no checkout of the child's repo); omit silently when absent.
   - **Full files for every touched path**, fetched via `gh api /repos/<owner>/<repo>/contents/<path>?ref=<reviewed-sha>` — the diff alone hides surrounding context. **Instruct the reviewer NOT to attempt local file reads:** a cross-repo child may have no checkout in this session, so every byte it needs must be in the prompt.
   - **Cross-cutting epic context** from Phase 1: the parent spec, this child's acceptance criteria **verbatim with their sub-issue ID**, merged-sibling decisions, and pending children's criteria — with the instruction to additionally evaluate (a) which acceptance bullets this diff satisfies/misses, citing them **by sub-issue ID and bullet**, and (b) forward-looking flags where a pending sub-issue will exercise this code differently.
3. **Per-tick post gate** (first review pass of this tick only): show the assembled review — inline comments plus summary — via `AskUserQuestion` for a single go/no-go. Approval covers this and **every subsequent post in this tick** (see Hard Rules — consent can't persist across ticks because no consent marker is stored); decline → halt the loop and `CronDelete` via the Phase 0 match rule. Later passes in the same tick skip this step entirely.
4. **Re-check PR state, then post.** After gate approval and immediately before posting, re-read the PR state (`gh pr view <n> --repo <owner>/<repo> --json state,mergedAt`); if it is merged or closed → **skip this target with `[merged-before-post]`, drop no marker** — a review on a merged PR is noise and would burn the dedup marker. Otherwise post the review in one `gh api` call: `POST /repos/<owner>/<repo>/pulls/<pr>/reviews` with `event: COMMENT`, `commit_id: <reviewed-sha>` (pins the review to the exact SHA reviewed — without it GitHub attaches to the latest HEAD and inline comments mis-anchor when the branch has moved), the reviewer's inline comments as the `comments` array, and a **summary body** with explicit structure:
   - **(a) Inline comments** — one-line index of what was flagged.
   - **(b) Spec cross-reference** — "satisfies ST-N bullet X … misses ST-N bullet Y", citing specific acceptance bullets by sub-issue ID, never free-text paraphrase.
   - **(c) Forward-looking flags** — "ST-N+1 will exercise this path differently; current shape will need rework", citing the pending child.

   **Post-failure guard:** if the review POST returns 4xx, halt this PR's pass **without dropping the step-5 dedup marker** and surface the response body in the tick output. The marker is written only after the post succeeds — otherwise a malformed payload would burn the review *and* mark the HEAD reviewed, and the loop would never retry it.
5. Drop the dedup marker as a **marker-only** top-level PR comment (the marker is the entire body, matching the `<!-- ship-issue:* -->` marker-only convention): `gh pr comment <n> --repo <owner>/<repo> --body '<!-- review-epic:reviewed-at:<reviewed-sha> -->'` where `<reviewed-sha>` is the pinned value from step 1 (the SHA the review was actually produced against), **not** a freshly re-read HEAD.
6. **Compact-between-reviews boundary** — see Phase 4 before starting the next target.

## Phase 4: Compact between reviews

Consumer of [`../_shared/compact-on-merge.md`](../_shared/compact-on-merge.md) at the **"between two PR reviews"** boundary: after a review pass completes (marker dropped) and **one or more un-reviewed targets remain in this tick's queue**, print — as the last output of the tick —

```
🗜 Review of <pr-url> posted. Run /compact now to free context before reviewing <next-pr-url>.
```

then **end the tick** (same end-the-wake rule as the workers — the dedup markers persist on the PRs, so the next tick's Phase 2 picks up exactly the remaining targets). Skip in no-compact mode, and when the just-reviewed PR was the only/last target. At most once per tick.

## Phase 5: Termination

On every tick, before Phase 1, re-check the parent:

- **Parent `state=closed`** (any reason) → terminal. To build the reviewed-PRs summary, **re-run Phase 2 enumeration with the state filters dropped** — all children (including `[x]`-completed task-list entries), `gh pr list ... --state all` — because by termination every reviewed child PR is merged/closed and the default `--state open` enumeration would find nothing to scan for `<!-- review-epic:reviewed-at:* -->` markers. Print the summary with thread links, `CronDelete` the loop's own cron entry via the Phase 0 match rule, and exit cleanly. This lands within one tick of the parent closing.
- User-invoked `Ctrl-C` / loop cancellation needs no cleanup — every tick re-derives from GitHub; markers already posted keep dedup correct on any future re-arm.

If `CronDelete` fails, print a note ("couldn't auto-cancel; run /loop cancel") and continue — the summary is the authoritative surface.

## Phase 6: Output contract (every tick)

```
/review-epic-gh tick <timestamp>
Parent: <owner>/<repo>#<n>  "<title>"  (open, 3 of 6 children merged)

  [reviewed]            PR #43 (child #39)  5 inline, 2 spec-refs, 1 forward flag
  [skipped]             PR #44 (child #40)  marker matches HEAD abc1234
  [head-moved]          PR #45 (child #41)  HEAD advanced mid-tick; re-review next tick
  [merged-before-post]  PR #46 (child #42)  merged after gate; no review posted
  [no-pr-yet]           child #50, #51

Next tick: /loop 12m /abc:review-epic-gh <raw-arg>
```

One line on no-op ticks: `no-op tick — no new commits on any child PR`.

## Notes on persistence

Stateless across sessions — GitHub is the source of truth. The `<!-- review-epic:reviewed-at:<sha> -->` markers on the PRs are the entire dedup store; closing the terminal mid-loop is safe, and a force-push that discards a marker simply triggers a benign re-review. Append markers, never edit them.
