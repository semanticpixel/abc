#!/usr/bin/env bash
set -euo pipefail

# Stay-awake hook for the abc plugin.
# Prevents macOS from sleeping while Claude Code is actively working —
# important for long-running autonomous loops (e.g. /abc:ship-issue self-arming /loop).
#
# Uses `caffeinate -w $PPID` so the background process auto-exits when
# the parent Claude Code process dies. No orphan-process risk.
#
# Environment variables:
#   CLAUDE_ABC_AWAKE_FLAGS         Flags passed to caffeinate (default: -i -m -s)
#   CLAUDE_ABC_AWAKE_ON_ACTIVATE   Optional command to run when stay-awake activates
#   CLAUDE_ABC_AWAKE_ON_DEACTIVATE Optional command to run when stay-awake deactivates

# Graceful no-op on platforms / environments without required tools.
command -v jq >/dev/null 2>&1 || exit 0
command -v caffeinate >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[[ -z "$EVENT" ]] && exit 0

AWAKE_FLAGS="${CLAUDE_ABC_AWAKE_FLAGS:--i -m -s}"
MATCH="caffeinate -w $PPID $AWAKE_FLAGS"

fire_activate() {
  [[ -n "${CLAUDE_ABC_AWAKE_ON_ACTIVATE:-}" ]] && eval "$CLAUDE_ABC_AWAKE_ON_ACTIVATE" >/dev/null 2>&1 || true
}

fire_deactivate() {
  [[ -n "${CLAUDE_ABC_AWAKE_ON_DEACTIVATE:-}" ]] && eval "$CLAUDE_ABC_AWAKE_ON_DEACTIVATE" >/dev/null 2>&1 || true
}

stop_awake() {
  pkill -f "$MATCH" 2>/dev/null && fire_deactivate || true
}

start_awake() {
  pgrep -f "$MATCH" >/dev/null 2>&1 && return
  # shellcheck disable=SC2086 — intentional word splitting for flags
  nohup caffeinate -w "$PPID" $AWAKE_FLAGS </dev/null >/dev/null 2>&1 &
  fire_activate
}

case "$EVENT" in
  UserPromptSubmit)
    start_awake
    ;;
  Stop|Notification)
    stop_awake
    ;;
  SessionEnd)
    stop_awake
    ;;
  PostToolUseFailure)
    # Only stop on user interrupt, not on regular tool failures.
    IS_INTERRUPT="$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null || true)"
    [[ "$IS_INTERRUPT" == "true" ]] && stop_awake
    ;;
  *)
    ;;
esac

exit 0
