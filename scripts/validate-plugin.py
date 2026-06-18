#!/usr/bin/env python3
"""Validate the abc plugin marketplace structure.

Checks:
- All JSON manifests parse.
- The `abc` plugin entry version in marketplace.json matches plugin.json version.
- Every SKILL.md and agent .md has YAML frontmatter that parses cleanly to a dict
  with at least `name` and `description` keys.
- Each skill's frontmatter `name` matches its directory name.
- `allowed-tools` is a list of strings and every `Bash(…)` grant uses the
  documented scoping syntax (`Bash(<cmd>:*)` prefix grants, or an exact /
  wildcard command with no stray colon).
- The reviewer/triage agents grant only the read-only tool set (a `Write` grant
  fails CI — these subagents are read-only by contract).
- hooks.json event names are real Claude Code lifecycle events, every `command`
  path under ${CLAUDE_PLUGIN_ROOT} resolves to a file on disk, and every
  hooks/*.sh script is executable.
- The current plugin.json version has both a `## [x.y.z]` CHANGELOG section and a
  matching `[x.y.z]:` link definition, and every versioned CHANGELOG section has
  a link definition (no dangling compare links).

Run locally: python3 scripts/validate-plugin.py
Requires: PyYAML (`pip install pyyaml`).
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "Validation FAILED: PyYAML is required. Install with `pip install pyyaml`.",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
PLUGIN_ROOT = ROOT / "plugins" / "abc"

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


# 1. JSON manifests parse
manifest_paths = [
    ROOT / ".claude-plugin" / "marketplace.json",
    PLUGIN_ROOT / ".claude-plugin" / "plugin.json",
    PLUGIN_ROOT / "hooks" / "hooks.json",
]

manifests: dict[Path, dict] = {}
for path in manifest_paths:
    if not path.exists():
        err(f"missing manifest: {rel(path)}")
        continue
    try:
        manifests[path] = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        err(f"invalid JSON in {rel(path)}: {e}")

# 2. Version alignment between marketplace.json's plugin entry and plugin.json
marketplace = manifests.get(ROOT / ".claude-plugin" / "marketplace.json")
plugin = manifests.get(PLUGIN_ROOT / ".claude-plugin" / "plugin.json")
if marketplace and plugin:
    entry = next(
        (p for p in marketplace.get("plugins", []) if p.get("name") == "abc"),
        None,
    )
    if entry is None:
        err("marketplace.json has no plugins[] entry with name='abc'")
    elif entry.get("version") != plugin.get("version"):
        err(
            "version mismatch: "
            f"marketplace.json plugins[abc].version={entry.get('version')!r} "
            f"!= plugin.json version={plugin.get('version')!r}"
        )


def load_frontmatter(md: Path):
    """Parse a markdown file's YAML frontmatter.

    Returns (fm_dict, None) on success or (None, error_message) on failure.
    """
    text = md.read_text()
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return None, f"missing YAML frontmatter (first line must be `---`): {rel(md)}"
    closing = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            closing = i
            break
    if closing is None:
        return None, f"unterminated YAML frontmatter (no closing `---`): {rel(md)}"
    block = "\n".join(lines[1:closing])
    try:
        fm = yaml.safe_load(block)
    except yaml.YAMLError as e:
        return None, f"YAML frontmatter does not parse in {rel(md)}: {e}"
    if not isinstance(fm, dict):
        return None, (
            f"YAML frontmatter in {rel(md)} parsed to {type(fm).__name__}, "
            "expected a mapping (dict). Often caused by a description starting "
            "with `[` — YAML reads it as a flow sequence. Use a plain-scalar "
            "separator (e.g. `Foo · ...`) instead, or quote the whole string."
        )
    return fm, None


def check_bash_scope(entry: str, where: str) -> None:
    """Validate a single `Bash(...)` allowed-tools grant.

    Accepts prefix grants ending in `:*` (`Bash(git status:*)`), exact commands,
    and wildcard commands with no colon (`Bash(git -C * remote get-url *)`).
    Rejects malformed parens, empty specs, and prefix grants that omit `:*`.
    """
    if entry == "Bash":  # valid (grants all bash) — over-broad but not malformed
        return
    m = re.fullmatch(r"Bash\(([^()]*)\)", entry)
    if m is None:
        err(f"malformed Bash scope (expected `Bash(<cmd>[:*])`): {entry!r} in {where}")
        return
    spec = m.group(1)
    if not spec or spec != spec.strip():
        err(f"empty or padded Bash scope: {entry!r} in {where}")
    elif ":" in spec and not re.fullmatch(r"[^:]+:\*", spec):
        # A colon means this is a prefix grant: require exactly one `<cmd>:*`
        # (non-empty command, single colon). Rejects `Bash(:*)` (empty prefix)
        # and `Bash(a:b:*)` (multi-segment) — both over-broad vs the contract.
        err(
            f"Bash prefix grant must be a single `<cmd>:*` (got {entry!r}) in {where} — "
            "use `Bash(<cmd>:*)` for prefix grants or drop the colon for an "
            "exact/wildcard command"
        )


# 3. Skill + agent frontmatter, name↔dir, allowed-tools scoping, agent tool set
skill_md = sorted((PLUGIN_ROOT / "skills").glob("*/SKILL.md"))
agent_md = sorted((PLUGIN_ROOT / "agents").glob("*.md"))

READONLY_AGENT_TOOLS = {"Read", "Grep", "Glob"}

for md in skill_md:
    fm, e = load_frontmatter(md)
    if e:
        err(e)
        continue
    for required in ("name", "description"):
        if required not in fm:
            err(f"YAML frontmatter in {rel(md)} is missing required key `{required}`")
    # name must match the directory name
    dirname = md.parent.name
    if fm.get("name") != dirname:
        err(
            f"skill frontmatter `name` ({fm.get('name')!r}) does not match its "
            f"directory ({dirname!r}) in {rel(md)}"
        )
    # allowed-tools: list of strings, Bash grants well-scoped
    tools = fm.get("allowed-tools")
    if tools is not None:
        if not isinstance(tools, list):
            err(f"`allowed-tools` in {rel(md)} must be a list, got {type(tools).__name__}")
        else:
            for t in tools:
                if not isinstance(t, str):
                    err(f"`allowed-tools` entry in {rel(md)} is not a string: {t!r}")
                elif t == "Bash" or t.startswith("Bash("):
                    check_bash_scope(t, rel(md))

for md in agent_md:
    fm, e = load_frontmatter(md)
    if e:
        err(e)
        continue
    for required in ("name", "description"):
        if required not in fm:
            err(f"YAML frontmatter in {rel(md)} is missing required key `{required}`")
    # reviewer/triage are read-only by contract — reject any non-read-only grant
    tools = fm.get("tools")
    if tools is not None:
        if not isinstance(tools, list):
            err(f"agent `tools` in {rel(md)} must be a list, got {type(tools).__name__}")
        else:
            extra = [t for t in tools if t not in READONLY_AGENT_TOOLS]
            if extra:
                err(
                    f"agent {rel(md)} grants non-read-only tool(s) {extra} — "
                    f"reviewer/triage are read-only by contract (allowed: "
                    f"{sorted(READONLY_AGENT_TOOLS)})"
                )

# 4. hooks.json — real event names, resolvable command paths, executable scripts
# Intentionally a CURATED typo-catching whitelist, NOT the full (~30-event)
# documented Claude Code hook set. It covers every event abc's hooks.json uses
# today; widen it when hooks.json adopts a new event, otherwise a valid-but-
# omitted event would red-CI.
VALID_HOOK_EVENTS = {
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "UserPromptSubmit",
    "Notification",
    "Stop",
    "SubagentStop",
    "SessionStart",
    "SessionEnd",
    "PreCompact",
}
hooks_json = manifests.get(PLUGIN_ROOT / "hooks" / "hooks.json")
if hooks_json:
    for event, groups in (hooks_json.get("hooks") or {}).items():
        if event not in VALID_HOOK_EVENTS:
            err(
                f"hooks.json: unknown hook event {event!r} "
                f"(valid events: {sorted(VALID_HOOK_EVENTS)})"
            )
        for group in groups or []:
            for h in group.get("hooks", []) or []:
                cmd = h.get("command", "") or ""
                for m in re.finditer(
                    r"\$\{CLAUDE_PLUGIN_ROOT\}/([A-Za-z0-9_./-]+)", cmd
                ):
                    target = PLUGIN_ROOT / m.group(1)
                    if not target.exists():
                        err(
                            f"hooks.json: command path does not resolve to a file: "
                            f"${{CLAUDE_PLUGIN_ROOT}}/{m.group(1)}"
                        )

# 5. Hook scripts executable
for sh in sorted((PLUGIN_ROOT / "hooks").glob("*.sh")):
    if not os.access(sh, os.X_OK):
        err(f"hook script not executable (chmod +x it before committing): {rel(sh)}")

# 6. CHANGELOG: current version has a section + link def; no dangling sections
changelog = ROOT / "CHANGELOG.md"
if not changelog.exists():
    err("missing CHANGELOG.md")
elif plugin:
    text = changelog.read_text()
    version = plugin.get("version")
    if version:
        if not re.search(rf"^##\s+\[{re.escape(version)}\]", text, re.M):
            err(f"CHANGELOG.md has no `## [{version}]` section for the current plugin version")
        if not re.search(rf"^\[{re.escape(version)}\]:\s+\S+", text, re.M):
            err(f"CHANGELOG.md has no `[{version}]:` link definition for the current plugin version")
    # Every versioned section heading needs a link definition.
    section_versions = re.findall(r"^##\s+\[([0-9][^\]]*)\]", text, re.M)
    linkdefs = set(re.findall(r"^\[([^\]]+)\]:", text, re.M))
    for v in section_versions:
        if v not in linkdefs:
            err(f"CHANGELOG.md: section `## [{v}]` has no `[{v}]:` link definition")

if errors:
    print("Validation FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(
    f"Validation OK: {len(manifest_paths)} manifests, "
    f"{len(skill_md)} skills, {len(agent_md)} agents."
)
