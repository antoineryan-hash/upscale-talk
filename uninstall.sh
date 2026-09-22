#!/usr/bin/env bash
#
# upscale-talk uninstaller
# Removes the Hammerspoon config block + the local model + the directory.
# Does NOT uninstall Hammerspoon / whisper.cpp / ffmpeg — those may be used by other things.
#
set -euo pipefail

echo "→ Removing upscale-talk Hammerspoon config block..."
if [ -f ~/.hammerspoon/init.lua ]; then
  # Remove the block between "-- ===== upscale-talk =====" markers if present;
  # otherwise remove lines containing "upscale-talk" headers.
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path.home() / ".hammerspoon" / "init.lua"
text = p.read_text()
# Remove from "-- ===== upscale-talk =====" to end of file (we always append at end)
new_text = re.sub(r"\n*-- ===== upscale-talk =====.*\Z", "", text, flags=re.DOTALL)
# Also handle the case where it was installed without the marker (first install path)
new_text = re.sub(r"\n*-- upscale-talk:.*\Z", "", new_text, flags=re.DOTALL)
p.write_text(new_text)
print(f"   Cleaned {p}")
PY
fi

echo "→ Removing the start-at-login agent..."
UT_LABEL="com.upscale.upscale-talk-autostart"
launchctl bootout "gui/$UID/$UT_LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$UT_LABEL.plist"

echo "→ Reloading Hammerspoon..."
open -g "hammerspoon://reload" 2>/dev/null || true

# Keep what cannot be regenerated. The model is a 547 MB download and the bin/
# scripts come from the repo, but transcriptions and meeting recordings exist
# nowhere else. Retiring the tool should not destroy someone's record of it.
echo "→ Removing ~/upscale-talk/ (model, helpers, scripts)..."
KEEP="$HOME/upscale-talk"
if [ -d "$KEEP" ]; then
  rm -rf "$KEEP/models" "$KEEP/bin" "$KEEP/scripts" "$KEEP/voices" \
         "$KEEP/telemetry.conf" "$KEEP/.heartbeat"
  if [ -d "$KEEP/history" ] || [ -d "$KEEP/meetings" ] || [ -d "$KEEP/archive" ]; then
    echo "   Kept your transcriptions: $KEEP/{history,meetings,archive}"
    echo "   Delete that folder yourself if you want it gone."
  else
    rmdir "$KEEP" 2>/dev/null || true
  fi
fi

echo "→ Cleaning /tmp..."
rm -f /tmp/upscale-talk*.wav /tmp/upscale-talk-diag.log

echo
echo "✅ Uninstall complete."
echo
echo "Not removed (may be used by other tools):"
echo "  - Hammerspoon         (brew uninstall --cask hammerspoon)"
echo "  - whisper.cpp         (brew uninstall whisper-cpp)"
echo "  - ffmpeg              (brew uninstall ffmpeg)"
echo "  - macOS dictation pref (defaults delete com.apple.HIToolbox AppleDictationAutoEnable)"
