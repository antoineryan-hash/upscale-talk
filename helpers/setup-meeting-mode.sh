#!/bin/bash
# setup-meeting-mode.sh — install upscale-talk MEETING MODE (double-tap fn) on THIS Mac.
#
# This is a PERSONAL / DEV setup, deliberately separate from the colleague
# one-liner (install.sh). Meeting mode uses a compiled Core Audio tap helper,
# which is exactly the "ceremony" the 2026-07-16 decision kept OUT of the free
# dictation tool. Run it from a repo checkout:
#
#     ~/Projects/upscale-talk/helpers/setup-meeting-mode.sh
#
# It builds/installs the tap helper + pipeline scripts under ~/upscale-talk/,
# checks the Python diarisation deps, and points you at the one permission only
# you can grant.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/upscale-talk"
BIN="$DEST/bin"
SCR="$DEST/scripts"

echo "→ Creating ~/upscale-talk/{bin,scripts,meetings,voices}"
mkdir -p "$BIN" "$SCR" "$DEST/meetings" "$DEST/voices"

echo "→ Building the system-audio tap helper (audiotee — Core Audio taps)"
if command -v swift >/dev/null 2>&1; then
  ( cd "$REPO/helpers/audiotee" && swift build -c release )
  cp "$REPO/helpers/audiotee/.build/release/audiotee" "$BIN/audiotee"
  echo "  built + installed $BIN/audiotee"
elif [ -f "$REPO/helpers/bin/audiotee" ]; then
  echo "  swift toolchain not found — using the vendored prebuilt binary"
  cp "$REPO/helpers/bin/audiotee" "$BIN/audiotee"
else
  echo "  ERROR: no swift toolchain and no prebuilt audiotee binary to install." >&2
  exit 1
fi

echo "→ Installing capture wrapper + pipeline scripts"
cp "$REPO/helpers/bin/capture-system.sh" "$BIN/"
cp "$REPO/scripts/meeting_transcribe.py" "$REPO/scripts/name_speakers.py" "$SCR/"
chmod +x "$BIN"/* "$SCR"/*.py

echo "→ Checking Python deps (whisper + resemblyzer, for far-side diarisation)"
if /usr/bin/python3 -c "import whisper, resemblyzer, sklearn, scipy, numpy" 2>/dev/null; then
  echo "  deps OK"
else
  echo "  MISSING — install them with:"
  echo "    /usr/bin/python3 -m pip install --user openai-whisper resemblyzer scikit-learn scipy numpy"
fi

echo ""
echo "→ ONE-TIME PERMISSION (only you can grant this):"
echo "  The tap needs macOS audio-recording permission for HAMMERSPOON (it runs"
echo "  the tap). The first time you double-tap fn, macOS should prompt — click"
echo "  Allow, then double-tap again to start. If no prompt appears, enable"
echo "  Hammerspoon under System Settings > Privacy & Security >"
echo "  'Screen & System Audio Recording' (or 'Audio Recording')."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" 2>/dev/null || true

echo ""
echo "✅ Meeting mode installed. Reload Hammerspoon (menubar > Reload Config),"
echo "   then double-tap fn to record a meeting; tap fn once to stop."
