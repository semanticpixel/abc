#!/usr/bin/env python3
"""Validate the abc plugin marketplace structure.

Checks:
- All JSON manifests parse.
- The `abc` plugin entry version in marketplace.json matches plugin.json version.
- Every SKILL.md and agent .md starts with YAML frontmatter (---).
- The stay-awake hook script is executable.

Run locally: python3 scripts/validate-plugin.py
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


# 1. JSON manifests parse
manifest_paths = [
    ROOT / ".claude-plugin" / "marketplace.json",
    ROOT / "plugins" / "abc" / ".claude-plugin" / "plugin.json",
    ROOT / "plugins" / "abc" / "hooks" / "hooks.json",
]

parsed: dict[Path, dict] = {}
for path in manifest_paths:
    if not path.exists():
        err(f"missing manifest: {rel(path)}")
        continue
    try:
        parsed[path] = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        err(f"invalid JSON in {rel(path)}: {e}")

# 2. Version alignment between marketplace.json's plugin entry and plugin.json
marketplace = parsed.get(ROOT / ".claude-plugin" / "marketplace.json")
plugin = parsed.get(ROOT / "plugins" / "abc" / ".claude-plugin" / "plugin.json")
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

# 3. YAML frontmatter on every SKILL.md and agent .md
skill_md = list((ROOT / "plugins" / "abc" / "skills").glob("*/SKILL.md"))
agent_md = list((ROOT / "plugins" / "abc" / "agents").glob("*.md"))
md_files = skill_md + agent_md
for md in md_files:
    lines = md.read_text().splitlines()
    if not lines or lines[0].strip() != "---":
        err(f"missing YAML frontmatter (first line must be `---`): {rel(md)}")

# 4. Hook script executable bit preserved
hook = ROOT / "plugins" / "abc" / "hooks" / "stay-awake.sh"
if hook.exists() and not os.access(hook, os.X_OK):
    err(f"hook script not executable (chmod +x it before committing): {rel(hook)}")

if errors:
    print("Validation FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(
    f"Validation OK: {len(manifest_paths)} manifests, "
    f"{len(skill_md)} skills, {len(agent_md)} agents."
)
