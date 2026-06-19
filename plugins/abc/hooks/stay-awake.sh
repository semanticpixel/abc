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
# Known race (bounded, self-healing): two near-simultaneous events in the SAME
# session can both pass the live_pid check before either writes the pidfile,
# spawning two caffeinate processes and orphaning the first (untracked, so
# teardown can't kill it). The orphan is harmless — it carries the same `-t TTL`
# and self-expires within TTL seconds — so it's accepted rather than locked
# against (flock is unavailable on macOS, the only platform this hook runs on).
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

# Read the pidfile's PID into REPLY if it names a live caffeinate process; else
# clear it. The `comm`-name check guards against OS PID reuse: a stale pidfile
# (SessionEnd never fired — crash, kill -9, reboot) can name a PID that the OS
# has since reassigned to an unrelated process, and `kill -0` alone would treat
# that as ours. Confirming the process is actually caffeinate before signalling
# it keeps teardown from ever SIGTERM-ing the wrong process.
live_pid() {
  REPLY=""
  [[ -f "$PIDFILE" ]] || return 0
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
     && [[ "$(ps -p "$pid" -o comm= 2>/dev/null)" == *caffeinate ]]; then
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
  # Guard the write: a read-only TMPDIR shouldn't abort the hook mid-refresh
  # under `set -e` (the caffeinate above has already spawned); degrade to the
  # same graceful no-op posture as the tool-availability guards up top.
  { echo $! > "$PIDFILE"; } 2>/dev/null || true
  # Use an explicit `if`, NOT `[[ … ]] && fire_activate`: on a warm refresh
  # was_live=1, so the `[[ ]]` is false and — as the function's last statement —
  # an `&&` compound would propagate exit 1. Under `set -e` that aborts the hook
  # before the trailing `exit 0`, surfacing a spurious "non-blocking status code:
  # No stderr output" on every Stop/UserPromptSubmit after the session's first.
  if [[ "$was_live" -eq 0 ]]; then fire_activate; fi
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
