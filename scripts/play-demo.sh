#!/usr/bin/env bash
# play-demo.sh — synthetic Claude Code session for the abc plugin README demo.
#
# Outputs a paced, scripted facsimile of the /abc:plan → /abc:scaffold-sub-issues-gh
# arc. NOT a real Claude Code invocation — we want a deterministic recording
# that vhs can render to GIF without needing API keys, tracker auth, or live
# LLM calls.
#
# Edit the say() / type_user() calls below to retune the arc. Tested with
# bash 3.2 (macOS default) and 5.x.
#
# Style helpers below mirror the look of Claude Code's terminal UI loosely —
# the visual signal we care about is: user prompt → working indicator → bullet
# output → confirmation gate → checkmark progress → handoff.

set -u

# --- style helpers ---------------------------------------------------------

dim()    { printf "\033[2m%s\033[0m" "$1"; }
bright() { printf "\033[1m%s\033[0m" "$1"; }
cyan()   { printf "\033[36m%s\033[0m" "$1"; }
green()  { printf "\033[32m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }

# Print + pause. Default beat is 0.4s; override for longer reads.
say() {
  printf "%b" "$1"
  sleep "${2:-0.4}"
}

# Type a string with per-character delay so it feels like the user is typing.
type_user() {
  local text="$1"
  local i ch
  for ((i = 0; i < ${#text}; i++)); do
    ch="${text:$i:1}"
    printf "%s" "$ch"
    sleep 0.028
  done
  printf "\n"
}

# Render a user-input prompt line and type the given command.
prompt() {
  printf "%s " "$(cyan '❯')"
  type_user "$1"
}

# --- the demo --------------------------------------------------------------

clear

# Set the scene with a one-line cwd hint, like Claude Code's typical header.
printf "%s\n" "$(dim '  ~/workspace/')"
sleep 0.4

# --- 1. /abc:plan ----------------------------------------------------------

prompt "/abc:plan turn @PLAN.md into a plan ready for /abc:scaffold-sub-issues-gh"
sleep 0.6

say "\n$(dim '✻ Reading PLAN.md (962 lines)…')\n" 1.4

say "\n$(bright '⏺') Draft plan written: $(cyan '~/.claude/plans/PLAN-personal-site-revamp.md')\n\n" 0.5

say "  10 sub-tasks (ST-0 → ST-9), one repo ($(cyan theluistorres))\n" 0.35
say "  Dependency graph: ST-1 unblocks 4 parallel streams\n" 0.35
say "  Acceptance criteria are verifiable — Lighthouse, bundle size, file greps\n" 0.6

say "\n  Next: $(cyan '/abc:scaffold-sub-issues-gh ~/.claude/plans/PLAN-personal-site-revamp.md')\n\n" 1.4

# --- 2. /abc:scaffold-sub-issues-gh ---------------------------------------

prompt "/abc:scaffold-sub-issues-gh ~/.claude/plans/PLAN-personal-site-revamp.md"
sleep 0.7

say "\n$(dim '✻ gh auth ok · gh 2.91.0 · hub = semanticpixel/theluistorres')\n" 1.1

say "\n$(bright '⏺') Proposed structure\n" 0.4
say "  Parent:    $(bright 'projectluis.com — design engineer revamp')\n" 0.3
say "  Children:  $(bright '10') sub-issues (ST-0 → ST-9), $(bright '15') dependency edges\n" 0.3
say "  Labels to create: $(yellow 'status:in-progress, status:in-review, repo:theluistorres')\n\n" 0.5

say "  $(bright 'Create everything as shown?') $(dim '[y/N]') " 1.2
say "$(cyan 'y')\n\n" 1.0

say "$(dim '✻ Creating labels, parent, sub-issues sequentially…')\n\n" 1.0

say "  $(green '✓') Created 3 labels\n" 0.45
say "  $(green '✓') Created parent: $(cyan 'semanticpixel/theluistorres#11')\n" 0.55
say "  $(green '✓') Created sub-issues $(cyan '#12 → #21')\n" 0.7
say "  $(green '✓') Wired $(bright '15') dependency edges\n\n" 0.9

say "  $(bright 'Dependency shape:')\n" 0.35
say "    ST-0 → ST-1 → { ST-2, ST-4, ST-7 }   $(dim '(parallel)')\n" 0.35
say "                   ST-2 → ST-3\n" 0.3
say "                   ST-2 + ST-4 → ST-5\n" 0.3
say "                   ST-4 + ST-5 → ST-6\n" 0.3
say "                   ST-3+ST-5+ST-6+ST-7 → ST-8 → ST-9\n\n" 0.8

say "  Next: $(cyan '/abc:ship-epic-gh semanticpixel/theluistorres#11')\n\n" 1.6
