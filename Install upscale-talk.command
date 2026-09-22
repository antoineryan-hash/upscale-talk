#!/usr/bin/env bash
#
# Install upscale-talk - double-clickable from Finder.
# https://github.com/antoineryan-hash/upscale-talk
#
# This file is deliberately a thin wrapper around install.sh and nothing else.
#
# It used to be a full second copy of the installer, 337 lines, kept by hand.
# It drifted: by September 2026 it was 34 days and 179 lines behind install.sh,
# and the thing it was missing was the start-at-login agent added on 20 August.
# Anyone who installed by double-clicking this file lost the tool at their next
# restart, silently. Marc Starrett found it on 2026-09-22; Tom Gibson had almost
# certainly been living with it since 13 August. It had also stopped upgrading
# anyone: its "already installed, skipping" test matched the whole config file,
# so any mention of upscale-talk anywhere in it meant a re-run installed nothing.
#
# There is one installer now. This file cannot fall behind it again.
#
set -euo pipefail

RAW="https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main"
HERE="$(cd "$(dirname "$0")" && pwd)"

cat <<'BANNER'

┌─────────────────────────────────────────────────────┐
│                                                     │
│  upscale-talk - voice-to-text for your Mac          │
│  Free, local, no cloud, no subscription             │
│                                                     │
└─────────────────────────────────────────────────────┘

About 5 minutes. You will be asked before anything is installed.

Press Enter to begin.
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

# The zip ships install.sh next to this file. Outside a zip, fetch it.
if [ -f "$HERE/files/install.sh" ]; then
  echo "→ Running the installer bundled with this download."
  run_script "$HERE/files/install.sh"
else
  echo "→ Fetching the latest installer from GitHub."
  TMP="$(mktemp)"
  if ! curl -fsSL "$RAW/install.sh" -o "$TMP"; then
    echo
    echo "❌ Couldn't download the installer. Check your internet connection"
    echo "   and try again. Nothing was installed."
    exit 1
  fi
  run_script "$TMP"
  rm -f "$TMP"
fi
