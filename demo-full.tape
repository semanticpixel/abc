# demo-full.tape — vhs script for the long-form abc plugin demo.
#
# Renders a ~60-second GIF showing the full /abc:plan → scaffold → ship-epic
# arc through to "all merged · parent closed · cron self-cancelled." Mirrors
# demo.tape's look (same font, theme, dimensions) so the two GIFs feel like
# a matched set — the README can lead with the short one for the elevator
# pitch and link the long one for viewers who want to see autonomy resolve.
#
# Prerequisites (Homebrew):
#   brew install vhs ttyd ffmpeg
#
# Render with:
#   vhs demo-full.tape
#
# Output: examples/demo-full.gif (committed; the README links it).
#
# To tweak pacing/content, edit scripts/play-demo-full.sh — the tape just
# runs that script. To tweak look (font, theme, dimensions), edit this file.

Output examples/demo-full.gif

Set Shell        bash
Set FontFamily   "JetBrains Mono"
Set FontSize     14
Set Width        1200
Set Height       760
Set TypingSpeed  35ms
Set Theme        "Catppuccin Mocha"

# Hide vhs's own boot-up so the recording starts on the demo content.
Hide
Type "clear"
Enter
Sleep 400ms
Show

# Run the synthetic Claude Code session.
Type "bash scripts/play-demo-full.sh"
Enter

# Hold the final frame so the closing "🎉 10 PRs merged" line stays readable.
# (Script itself runs ~60s; the Sleep below is a buffer beyond the last beat.)
Sleep 4s
