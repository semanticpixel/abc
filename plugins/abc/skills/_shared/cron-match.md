# cron-match — shared helper

Canonical definition of the **cron-entry match rule** used by the self-arming `/loop`
skills: how a skill recognizes its own already-armed `/loop` cron entry (so subsequent
wakes are a no-op instead of duplicate-arming) and how it finds that entry again to
`CronDelete` it on a terminal halt. The arm check and the self-cancel **must stay in
lockstep** — past edits drifted when the rule was inlined twice in the same skill.

**Consumed by:** `ship-issue`, `ship-issue-gh`, `ship-epic`, `ship-epic-gh`. Each
consumer references this file at its Phase 0.5 arm check and its Phase 7 / stop-flow
self-cancel rather than restating the rule.

---

## Parameters

Each consumer supplies two values; everything else is identical:

| Parameter | Meaning | Per-consumer value |
|---|---|---|
| `<skill>` | the skill's bare command name (no `/abc:` prefix) | `ship-issue` · `ship-issue-gh` · `ship-epic` · `ship-epic-gh` |
| `<boundary-class>` | the character class the next char after `<raw-arg>` must **not** belong to | **Linear** (`ship-issue`, `ship-epic`): alphanumeric, `-`, `,` · **GitHub** (`ship-issue-gh`, `ship-epic-gh`): alphanumeric, `-`, `,`, `/`, `#` |

`<command-name>` below is the literal slash-command name Claude Code injects for the
invocation (e.g. `/ship-issue` top-level, or `/<plugin>:ship-issue` through a plugin
namespace) — always read it from the `<command-name>` tag Claude Code passes at
invocation time, including on `/loop`-triggered wakes where the inner command name is
still surfaced.

## The rule

> A `CronList` entry **matches** this invocation when its command string contains
> `<command-name> <raw-arg>` **followed by a word boundary** — the next character (if
> any) must NOT be in `<boundary-class>`.
>
> Reading the **actually-injected** `<command-name>` — rather than hardcoding `/<skill>`
> — is load-bearing for plugin-namespaced invocations: the hardcoded substring `/<skill>`
> is **not** present in `/abc:<skill> <raw-arg>` (the prefix is `/abc:`, not `/`), so the
> match always failed and every wake duplicate-armed a new cron.
>
> **Fallback regex** when `<command-name>` isn't reachable (older Claude Code versions,
> edge cases): test the entry's command string against
> `(?:^|[^A-Za-z0-9])(?:[A-Za-z][A-Za-z0-9_-]*:)?<skill> <raw-arg>(?![A-Za-z0-9_,-])` —
> and for the GitHub `<boundary-class>`, the trailing negative-lookahead is
> `(?![A-Za-z0-9_,/#-])` instead (the `/` and `#` exclusions are GitHub-ID specific; the
> Linear siblings' rule doesn't need them). The optional `<plugin>:` prefix capture
> covers any plugin-namespacing scheme. This still prevents `PROJ-1` / `foo/bar#1` from
> false-matching an entry for `PROJ-10` / `foo/bar#10` (prefix) or a comma-continuation
> list (`PROJ-1,PROJ-2`).
>
> Boundary check works whether `CronList` reports the wrapped form
> `/loop <interval> <command-name> <raw-arg>` or the inner `<command-name> <raw-arg>`.

**Match key is the full raw arg string.** Two separate invocations with different args →
two independent loops. Substitute the captured `<command-name>` (not a hardcoded
`/<skill>`) when arming via `Skill(skill: "loop", args: "<interval> <command-name> <raw-arg>")`.
