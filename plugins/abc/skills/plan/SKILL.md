---
name: plan
description: Produce a draft PLAN-*.md file within the first few tool calls — structured for downstream consumption by /abc:scaffold-sub-issues (Linear issue creation) and /abc:ship-epic (parallel multi-repo shipping). Front-loads writing over Q&A. TRIGGER when the user says "/plan", "draft a plan for X", "write a PLAN doc", or asks Claude to plan a feature/migration/refactor before implementation.
argument-hint: "<short description of what to plan>"
model: opus
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Edit
  - AskUserQuestion
  - Bash(ls:*)
  - Bash(pwd:*)
  - Bash(git remote:*)
  - Bash(rg:*)
---

# /abc:plan — Draft a PLAN-*.md fast

Produce a structured plan document within a few tool calls — no extended clarifying-question loop. The output is shaped so that:

- `/abc:scaffold-sub-issues` (Linear) or `/abc:scaffold-sub-issues-gh` (GitHub Issues) can turn the sub-tasks into a parent + sub-issues. Pick the scaffold by tracker — the PLAN grammar is identical for both.
- `/abc:ship-epic` / `/abc:ship-epic-gh` (later) can read the sub-issue dependency graph and ship them in parallel.

The exact grammar these consumers parse — sub-task block fields, the relations sentinel, and where the validation gate attaches — is single-sourced in [`plan-format.md`](./plan-format.md). The skeleton below emits that grammar; keep them in sync.

## Hard rules

- **Write first, refine in place.** Within the first 3-5 tool calls, produce a draft `PLAN-<slug>.md` on disk. Then iterate via the file, not via Q&A. The user has explicitly said extended clarifying questions before any deliverable are an anti-pattern.
- **Always include the obvious adjacent sections** on the first pass: context, approach, sub-tasks (with repo + dependencies), open questions, validation. Even if a section is one line, write it — easier to delete than to retroactively add.
- **Never commit the PLAN file or push it.** It lives locally until the user decides where to keep it.
- **Use `repo:<name>` notation per sub-task** so the scaffold can map it to a `repo:<name>` label and `/abc:ship-epic[-gh]` can resolve it to a workdir. For a repo owned by a *different* org/user than the hub (the GitHub cross-owner case), write the fully-qualified `repo:<owner>/<name>` so `scaffold-sub-issues-gh` routes it to the right repo instead of assuming the hub owner.

## Where to put the file

Default: `~/.claude/plans/PLAN-<kebab-slug>.md` (keeps drafts out of project repos by default).

Override: if the user passes an explicit path or is inside a project repo and says "in this repo", write to `./PLAN-<kebab-slug>.md` in the cwd.

Slug: derive from the task description. Keep it short, kebab-case (e.g. `cuj-platform-poc`, `auth-migration`).

## Workflow

### Phase 0: Quick scoping (≤ 2 tool calls)

1. Read the task description. If it's a single line and ambiguous, ask **one** clarifying question via `AskUserQuestion` — only if you genuinely can't draft a useful skeleton without it. Most of the time, draft and let the user redirect from the file.
2. If the user mentions a specific repo or codebase: peek at the top-level structure (`ls`, `git remote get-url origin`, maybe one `rg` for related code). One or two reads max — this is scoping, not investigation.

### Phase 1: Write the draft (within the next 1-2 tool calls)

Create `PLAN-<slug>.md` with this skeleton:

```markdown
# PLAN: <Title>

**Status:** Draft
**Created:** <YYYY-MM-DD>
**Owner:** <inferred from user, or leave blank>

## Context

<2-4 sentences on why this work matters. The motivation, the user-visible
problem, or the technical pressure. NOT a feature spec — the *why*.>

## Approach

<2-4 sentences on the high-level technical strategy. What we're building
or changing at the system level, NOT a step-by-step. Reference repos by
name (e.g. "web-frontend", "analytics-tools") so
the reader knows what surfaces are involved.>

## Sub-tasks

> Each sub-task becomes a sub-issue via `/abc:scaffold-sub-issues` (Linear) or `/abc:scaffold-sub-issues-gh` (GitHub).
> `repo:` matches the `repo:<name>` label convention (`repo:<owner>/<name>` for a cross-owner GitHub repo).
> `blocks` / `blocked by` create the dependency graph for `/abc:ship-epic[-gh]`.
> Add a `validation:` bullet to the one sub-task whose merge should gate on manual verification (see `plan-format.md`).

### ST-1: <Short imperative title>
- **repo:** web-frontend
- **scope:** <1-2 sentences on what changes>
- **acceptance criteria:**
  - <bullet>
  - <bullet>
- **validation:** (optional) <how a human confirms this specific sub-task post-merge — attaches the `blocked-verify` gate to this child>
- **blocks:** (none | ST-N, ST-M)
- **blocked by:** (none | ST-N)

### ST-2: <…>
- …

## Open questions

- <Anything that requires a decision before sub-tasks are final.>

## Validation

<Parent-level: how we'll know the overall work landed correctly. Could be: manual
smoke test, specific metric to watch, "no regressions in X test suite", "a/b
experiment results within Y range". Single bullet or short list. To gate a
*specific* sub-task's merge on manual verification, put a `validation:` bullet in
that sub-task instead — a top-level section here stays unattached until the scaffold
asks who should inherit it.>

## Out of scope

<What we're deliberately NOT doing in this plan, to keep scope tight.>
```

### Phase 2: Tell the user what to do next

After the file is written, output to the terminal:

```
Draft plan written: <path>

Suggested next steps:
  1. Open the file and iterate — edit sub-tasks, acceptance criteria, dependencies.
  2. Create the tracker issues from the plan (pick by tracker):
       • Linear:  /abc:scaffold-sub-issues <path>
       • GitHub:  /abc:scaffold-sub-issues-gh <path>
  3. Once issues exist, ship them:
       • Linear:  /abc:ship-epic <PARENT-ID>      (or /abc:ship-issue for serial)
       • GitHub:  /abc:ship-epic-gh <owner>/<repo>#<N>  (or /abc:ship-issue-gh)
```

Do NOT then start interactively iterating on the plan in the conversation unless the user asks. The point is to give them a file to edit.

## Sub-task design guidance (apply while drafting)

- **One sub-task per repo, per logical change.** If the same change needs to land in two repos (e.g. shared type added in `@org/contracts`, consumed in `webapp`), that's TWO sub-tasks with a `blocks` relation.
- **Sub-tasks should be 1-3 days of work each.** If a sub-task feels bigger than that, split it. If it's smaller than 2 hours, fold it into an adjacent one.
- **Dependencies are sparse by default.** Most sub-tasks are independent. Only add `blocks` when there's a genuine ordering requirement (e.g. consumer can't compile until producer is published).
- **Acceptance criteria are verifiable.** "Improves performance" is not acceptance; "P95 latency on /search endpoint stays under 200ms" is.

## When NOT to use /abc:plan

- For a single-repo, ≤1-day task, just `/abc:ship-issue` from a Linear ticket directly. Plans are for multi-step, multi-repo, or multi-week work.
- For exploratory "what could we do?" conversations — answer in the chat; plans are for decisions, not ideation.
- For bug fixes — write the fix; the commit message is the plan.
