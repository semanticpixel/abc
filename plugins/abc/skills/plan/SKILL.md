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

- `/abc:scaffold-sub-issues` can turn the sub-tasks into a Linear parent + sub-issues.
- `/abc:ship-epic` (later) can read the sub-issue dependency graph and ship them in parallel.

## Hard rules

- **Write first, refine in place.** Within the first 3-5 tool calls, produce a draft `PLAN-<slug>.md` on disk. Then iterate via the file, not via Q&A. The user has explicitly said extended clarifying questions before any deliverable are an anti-pattern.
- **Always include the obvious adjacent sections** on the first pass: context, approach, sub-tasks (with repo + dependencies), open questions, validation. Even if a section is one line, write it — easier to delete than to retroactively add.
- **Never commit the PLAN file or push it.** It lives locally until the user decides where to keep it.
- **Use `repo:<name>` notation per sub-task** so `/abc:scaffold-sub-issues` can map it to a Linear `repo:` label and `/abc:ship-epic` can resolve it to a workdir.

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

> Each sub-task becomes a Linear sub-issue via `/abc:scaffold-sub-issues`.
> `repo:` matches the Linear `repo:<name>` label convention.
> `blocks` / `blocked by` create the dependency graph for `/abc:ship-epic`.

### ST-1: <Short imperative title>
- **repo:** web-frontend
- **scope:** <1-2 sentences on what changes>
- **acceptance criteria:**
  - <bullet>
  - <bullet>
- **blocks:** (empty | ST-N, ST-M)
- **blocked by:** (empty | ST-N)

### ST-2: <…>
- …

## Open questions

- <Anything that requires a decision before sub-tasks are final.>

## Validation

<How we'll know the work landed correctly. Could be: manual smoke test,
specific metric to watch, "no regressions in X test suite", "a/b experiment
results within Y range". Single bullet or short list.>

## Out of scope

<What we're deliberately NOT doing in this plan, to keep scope tight.>
```

### Phase 2: Tell the user what to do next

After the file is written, output to the terminal:

```
Draft plan written: <path>

Suggested next steps:
  1. Open the file and iterate — edit sub-tasks, acceptance criteria, dependencies.
  2. Run /abc:scaffold-sub-issues <path> when you're ready to create Linear issues.
  3. Once issues exist, run /abc:ship-epic <PARENT-ID> to ship in parallel.
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
