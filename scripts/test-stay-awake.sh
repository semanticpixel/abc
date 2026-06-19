#!/usr/bin/env bash
# Regression test for plugins/abc/hooks/stay-awake.sh exit codes.
#
# Guards the `set -e` + `&&`-as-last-statement footgun that made refresh_awake()
# return 1 on every WARM event (Stop / UserPromptSubmit after the session's
# first), which Claude Code surfaced as
#   "<event> hook error: Failed with non-blocking status code: No stderr output"
# on every turn. The hook must exit 0 on cold start AND on every warm refresh.
#
# Hermetic: throwaway session_id, kills its own caffeinate, removes its pidfile.
# Skips gracefully where jq or caffeinate are unavailable (mirrors the hook's
# own `command -v … || exit 0` guards), so it no-ops cleanly on non-macOS CI.
set -uo pipefail

command -v jq >/dev/null 2>&1         || { echo "SKIP: jq not found"; exit 0; }
command -v caffeinate >/dev/null 2>&1 || { echo "SKIP: caffeinate not found (non-macOS)"; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../plugins/abc/hooks/stay-awake.sh"
SESSION="test-stay-awake-$$"
PIDFILE="${TMPDIR:-/tmp}/claude-abc-awake-${SESSION}.pid"

# shellcheck disable=SC2329  # invoked indirectly via the EXIT trap
cleanup() {
  if [[ -f "$PIDFILE" ]]; then
    local pid
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then kill "$pid" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

ev() { printf '{"hook_event_name":"%s","session_id":"%s"}' "$1" "$SESSION"; }

fail=0
run() { # <event> <label>
  ev "$1" | bash "$HOOK"
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "ok   ($rc)  $2"
  else
    echo "FAIL ($rc)  $2"
    fail=1
  fi
}

# Cold start, then repeated warm events on the noisy surfaces. The warm calls
# are the regression: pre-fix they exited 1; they must now exit 0.
run UserPromptSubmit "cold UserPromptSubmit (was_live=0)"
run Stop             "warm Stop (was_live=1)"
run UserPromptSubmit "warm UserPromptSubmit (was_live=1)"
run Notification     "warm Notification (was_live=1)"
run Stop             "warm Stop again (was_live=1)"

# A live caffeinate should exist and be recorded in the pidfile.
if [[ -f "$PIDFILE" ]] && pid="$(cat "$PIDFILE")" && kill -0 "$pid" 2>/dev/null; then
  echo "ok   pidfile names a live caffeinate ($pid)"
else
  echo "FAIL pidfile missing or names no live caffeinate"
  fail=1
fi

# Teardown exits 0 and removes the pidfile.
run SessionEnd "SessionEnd teardown"
if [[ -f "$PIDFILE" ]]; then
  echo "FAIL pidfile survived SessionEnd"
  fail=1
else
  echo "ok   pidfile removed on SessionEnd"
fi

if [[ $fail -eq 0 ]]; then echo "PASS"; else echo "FAILED"; fi
exit $fail
