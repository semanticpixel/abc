# demo.tape — vhs script for the abc plugin marketplace README demo.
#
# Renders a ~30-second GIF showing the /abc:plan → /abc:scaffold-sub-issues-gh
# arc against a real plan, so a reader lands on the README and immediately
# sees the toolkit creating a 10-issue dependency-graph epic from a markdown
# file.
#
# Prerequisites (Homebrew):
#   brew install vhs ttyd ffmpeg
#
# Render with:
#   vhs demo.tape
#
# Output: examples/demo.gif (committed; the README embeds it).
#
# To tweak pacing/content, edit scripts/play-demo.sh — the tape just runs
# that script. To tweak look (font, theme, dimensions), edit this file.

Output examples/demo.gif

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
Type "bash scripts/play-demo.sh"
Enter

# Hold the final frame so the closing summary stays readable.
Sleep 3s
