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

# --- 3. /abc:ship-epic-gh — arm the coordinator + first worker ------------

prompt "/abc:ship-epic-gh semanticpixel/theluistorres#11"
sleep 0.7

say "\n$(dim '✻ Parsing parent #11 + 10 children · checking auth + cron state')\n" 1.0

say "\n$(bright '⏺') Dependency graph\n" 0.4
say "    #12 ← $(green '(ready)')\n" 0.18
say "    #13 ← #12\n"             0.12
say "    #14 ← #13\n"             0.12
say "    #15 ← #14\n"             0.12
say "    #16 ← #13\n"             0.12
say "    #17 ← #14, #16\n"        0.12
say "    #18 ← #16, #17\n"        0.12
say "    #19 ← #13\n"             0.12
say "    #20 ← #15, #17, #18, #19\n" 0.12
say "    #21 ← #20\n\n"           0.5

say "    No cycles. 1 ready ($(cyan '#12')). Arming loops.\n\n" 0.6

say "  $(green '✓') Epic cron armed     $(dim '(every 10m)')\n" 0.4
say "  $(green '✓') Worker cron armed   $(dim '(every 6m, #12)')\n\n" 1.0

# --- 4. The first worker — full PR lifecycle on #12 -----------------------

say "$(dim '✻ Worker · #12 ST-0 Convert repo toolchain to pnpm')\n\n" 0.9

say "  $(green '✓') Branch    $(cyan '12-st-0-convert-repo-toolchain-to-pnpm')\n" 0.4
say "  $(green '✓') Label     status:in-progress\n" 0.35
say "  $(green '✓') Implement $(dim '(Yarn PnP → pnpm config, .pnp.cjs / yarn.lock removal)')\n" 0.6
say "  $(green '✓') Local checks pass $(dim '(typecheck, install)')\n" 0.4
say "  $(green '✓') Commit    $(cyan '755d13d')\n" 0.4
say "  $(green '✓') Push      + PR $(cyan '#22') opened\n" 0.5
say "  $(green '✓') Label     status:in-progress → $(yellow 'status:in-review')\n\n" 1.0

# --- 5. Epic-level status block at end of the first wake ------------------

say "$(bright '/abc:ship-epic-gh wake') — first iteration done\n" 0.4
say "Parent: $(cyan 'semanticpixel/theluistorres#11')  $(dim '(0 of 10 merged)')\n\n" 0.5

say "  $(yellow '[in-flight]')   #12  pr-open · $(cyan 'pull/22')\n" 0.25
say "  $(dim '[waiting]')     #13–#21  (9 children gated on the chain)\n\n" 0.5

say "  Next wake: $(dim '/loop 10m /abc:ship-epic-gh #11')\n\n" 1.4

# --- 6. Time-jump · cascade as PRs merge ---------------------------------

say "            $(dim '──────── T+12m · PR #22 merges ────────')\n\n" 1.0

say "$(dim '✻ Epic wake · #12 merged · #13 unblocked')\n\n" 0.7

say "  $(green '✓') #12 merged          $(dim '(PR #22)')  ST-0 pnpm migration\n" 0.3
say "  $(dim '↳') Worker cron $(dim '96362468')  self-cancelled\n" 0.3
say "  $(green '→') Firing worker for $(cyan '#13')  ST-1 Astro 5 scaffold\n\n" 1.0

# Mid-cycle: a per-worker no-op wake, showing the polling loop in action.
say "            $(dim '──────── T+24m · worker poll ────────')\n\n" 0.9

say "$(dim '✻ Worker wake · #13')\n" 0.4
say "  $(dim 'pr-open · no new review comments · checks passing · next 6m')\n\n" 1.2

# Fan-out: ST-1 merges, three children become ready simultaneously.
say "            $(dim '──────── T+38m · #13 merges · fan-out ────────')\n\n" 1.0

say "$(dim '✻ Epic wake · #13 merged · 3 children unblock at once')\n\n" 0.7

say "  $(green '✓') #13 merged          $(dim '(PR #23)')  ST-1 Astro scaffold + tokens\n" 0.3
say "  $(green '→') Firing 3 workers in parallel:\n" 0.4
say "      $(cyan '#14') ST-2 Hero shell           $(dim '→ PR #25')\n" 0.22
say "      $(cyan '#16') ST-4 Case studies         $(dim '→ PR #26')\n" 0.22
say "      $(cyan '#19') ST-7 Sandbox + 404 + OG   $(dim '→ PR #27')\n\n" 0.7

say "  $(bright 'CronList')\n" 0.3
say "    c047915b  $(dim 'epic    10m')   #11\n"  0.12
say "    69b4fcb3  $(dim 'worker   6m')   #14\n"  0.12
say "    81ff9155  $(dim 'worker   6m')   #16\n"  0.12
say "    40603fcf  $(dim 'worker   6m')   #19\n\n" 0.7

# Authentic detail: workers flag cross-PR conflicts in the batch summary.
say "  $(yellow '⚠')  $(dim 'Worker flagged:') #25 ⇄ #26 conflict on $(cyan 'src/pages/index.astro')\n" 0.45
say "      $(dim 'Surface only — review/merge order is the human\047s call')\n\n" 1.2

# A no-op epic wake: nothing changed, but the coordinator still polled.
say "            $(dim '──────── T+50m · epic poll ────────')\n\n" 0.9

say "$(dim '✻ no-op wake — 2 of 10 merged, 3 in-flight, 5 waiting · next 10m')\n\n" 1.2

# --- 7. Terminal state — all merged, autonomy resolved -------------------

say "            $(dim '──────── later that afternoon ────────')\n\n" 1.2

say "$(bright '/abc:ship-epic-gh wake') — terminal\n" 0.4
say "Parent: $(cyan 'semanticpixel/theluistorres#11')  $(green '(10 of 10 merged · ✅)')\n\n" 0.6

say "  $(green '✓') #12  ST-0  pnpm migration                  $(dim '→ PR #22')\n" 0.15
say "  $(green '✓') #13  ST-1  Astro 5 scaffold + tokens       $(dim '→ PR #23')\n" 0.15
say "  $(green '✓') #14  ST-2  Site shell + home hero          $(dim '→ PR #25')\n" 0.15
say "  $(green '✓') #15  ST-3  Contributions pipeline          $(dim '→ PR #29')\n" 0.15
say "  $(green '✓') #16  ST-4  Content collections (5 cs)      $(dim '→ PR #26')\n" 0.15
say "  $(green '✓') #17  ST-5  About + Writing + Colophon      $(dim '→ PR #30')\n" 0.15
say "  $(green '✓') #18  ST-6  Spanish locale (/es)            $(dim '→ PR #31')\n" 0.15
say "  $(green '✓') #19  ST-7  Sandbox + 404 + OG images       $(dim '→ PR #27')\n" 0.15
say "  $(green '✓') #20  ST-8  CI + perf + a11y + budgets      $(dim '→ PR #32')\n" 0.15
say "  $(green '✓') #21  ST-9  Cutover — Astro is production   $(dim '→ PR #33')\n\n" 0.6

say "  $(dim 'Parent #11 closed · cron') $(dim 'c047915b') $(dim 'self-cancelled.')\n\n" 0.8

say "  🎉 10 PRs merged in one afternoon. Site is live.\n\n" 1.6
