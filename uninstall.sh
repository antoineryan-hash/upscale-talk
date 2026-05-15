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

echo "→ Reloading Hammerspoon..."
open -g "hammerspoon://reload" 2>/dev/null || true

echo "→ Removing ~/.upscale-talk/ (model + tmp)..."
rm -rf ~/.upscale-talk

echo
echo "✅ Uninstall complete."
echo
echo "Not removed (may be used by other tools):"
echo "  - Hammerspoon         (brew uninstall --cask hammerspoon)"
echo "  - whisper.cpp         (brew uninstall whisper-cpp)"
echo "  - ffmpeg              (brew uninstall ffmpeg)"
echo "  - macOS dictation pref (defaults delete com.apple.HIToolbox AppleDictationAutoEnable)"
