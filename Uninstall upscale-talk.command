#!/usr/bin/env bash
#
# Uninstall upscale-talk - double-clickable from Finder.
#
# A thin wrapper around uninstall.sh, for the same reason as the installer: this
# file used to be a second copy, and it had drifted. It never removed the
# start-at-login agent, so uninstalling by double-click left a LaunchAgent that
# went on re-opening Hammerspoon at every login after the tool was gone.
#
set -euo pipefail

RAW="https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main"
HERE="$(cd "$(dirname "$0")" && pwd)"

cat <<'BANNER'

┌─────────────────────────────────────────────────────┐
│  Uninstall upscale-talk                             │
└─────────────────────────────────────────────────────┘

This will remove:
  • The upscale-talk block from ~/.hammerspoon/init.lua
  • The start-at-login agent
  • The Whisper model and the helper scripts

This will NOT remove:
  • Your transcriptions and meeting recordings
    (they stay in ~/upscale-talk/ - delete that folder yourself if you
     want them gone)
  • Hammerspoon, whisper.cpp, ffmpeg - other things may use them

Press Enter to continue, or Ctrl-C to cancel.

BANNER
read -r

finish() {
  echo
  echo "Press Enter to close..."
  read -r
}
trap finish EXIT

# Run with the real terminal on stdin when there is one. Double-clicked from
# Finder there always is; piped in a test harness there may not be, and
# redirecting from a /dev/tty that cannot be opened kills the script.
run_script() {
  if ( exec 3< /dev/tty ) 2>/dev/null; then
    bash "$1" < /dev/tty
  else
    bash "$1"
  fi
}

if [ -f "$HERE/files/uninstall.sh" ]; then
  run_script "$HERE/files/uninstall.sh"
else
  TMP="$(mktemp)"
  if ! curl -fsSL "$RAW/uninstall.sh" -o "$TMP"; then
    echo "❌ Couldn't download the uninstaller. Check your internet connection."
    exit 1
  fi
  run_script "$TMP"
  rm -f "$TMP"
fi
