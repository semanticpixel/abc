#!/usr/bin/env bash
set -euo pipefail

# Stay-awake hook for the abc plugin.
# Prevents macOS from sleeping while Claude Code is actively working —
# important for long-running autonomous loops (e.g. /abc:ship-issue self-arming /loop).
#
# TTL model: every handled event (UserPromptSubmit, Stop, Notification,
# PostToolUseFailure) spawns/refreshes a `caffeinate -t <TTL>` process. The
# assertion self-expires <TTL> seconds after the last activity, so it survives
# the gap between a Stop and the next /loop wake (≈6 min) without being killed
# at end-of-turn. SessionEnd is the hard off-switch.
#
# The spawned caffeinate PID is written to a session-keyed pidfile so that
# dedup (don't stack assertions) and teardown (kill the exact PID) never touch
# another concurrent session's caffeinate. No `pgrep -f` / `pkill -f`.
#
# Environment variables (CLAUDE_ABC_AWAKE_ON_* execute as shell commands):
#   CLAUDE_ABC_AWAKE_FLAGS         Flags passed to caffeinate (default: -i -m -s)
#   CLAUDE_ABC_AWAKE_TTL           Assertion lifetime in seconds (default: 900 ≈ 2 loop intervals)
#   CLAUDE_ABC_AWAKE_ON_ACTIVATE   Optional command run when stay-awake first activates
#   CLAUDE_ABC_AWAKE_ON_DEACTIVATE Optional command run when stay-awake deactivates

# Graceful no-op on platforms / environments without required tools.
command -v jq >/dev/null 2>&1 || exit 0
command -v caffeinate >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
EVENT="$(echo "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[[ -z "$EVENT" ]] && exit 0

AWAKE_FLAGS="${CLAUDE_ABC_AWAKE_FLAGS:--i -m -s}"
TTL="${CLAUDE_ABC_AWAKE_TTL:-900}"

# Session-keyed pidfile: distinct sessions never kill each other's caffeinate.
SESSION_KEY="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -z "$SESSION_KEY" ]] && SESSION_KEY="ppid-$PPID"
SESSION_KEY="${SESSION_KEY//[^A-Za-z0-9_-]/_}"
PIDFILE="${TMPDIR:-/tmp}/claude-abc-awake-${SESSION_KEY}.pid"

fire_activate() {
  [[ -n "${CLAUDE_ABC_AWAKE_ON_ACTIVATE:-}" ]] && ( bash -c "$CLAUDE_ABC_AWAKE_ON_ACTIVATE" >/dev/null 2>&1 & ) || true
}

fire_deactivate() {
  [[ -n "${CLAUDE_ABC_AWAKE_ON_DEACTIVATE:-}" ]] && ( bash -c "$CLAUDE_ABC_AWAKE_ON_DEACTIVATE" >/dev/null 2>&1 & ) || true
}

# Read the pidfile's PID into REPLY if it names a live process; else clear it.
live_pid() {
  REPLY=""
  [[ -f "$PIDFILE" ]] || return 0
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    REPLY="$pid"
  fi
}

# Spawn (or refresh) the assertion: kill any live predecessor, start a fresh
# caffeinate with a full TTL, record its PID. fire_activate only on cold start.
refresh_awake() {
  local was_live=0
  live_pid
  if [[ -n "$REPLY" ]]; then
    was_live=1
    kill "$REPLY" 2>/dev/null || true
  fi
  # Intentional word splitting for flags.
  # shellcheck disable=SC2086
  nohup caffeinate $AWAKE_FLAGS -t "$TTL" </dev/null >/dev/null 2>&1 &
  echo $! > "$PIDFILE"
  [[ "$was_live" -eq 0 ]] && fire_activate
}

stop_awake() {
  live_pid
  if [[ -n "$REPLY" ]]; then
    kill "$REPLY" 2>/dev/null && fire_deactivate || true
  fi
  rm -f "$PIDFILE"
}

case "$EVENT" in
  UserPromptSubmit|Stop|Notification|PostToolUseFailure)
    refresh_awake
    ;;
  SessionEnd)
    stop_awake
    ;;
  *)
    ;;
esac

exit 0
