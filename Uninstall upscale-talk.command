#!/usr/bin/env bash
#
# Uninstall upscale-talk
#
set -euo pipefail

cat <<'BANNER'

┌─────────────────────────────────────────────────────┐
│  Uninstall upscale-talk                             │
└─────────────────────────────────────────────────────┘

This will remove:
  • The upscale-talk block from ~/.hammerspoon/init.lua
  • The ~/upscale-talk/ folder (including transcription history)
  • The /tmp working files

This will NOT remove (they may be used by other tools):
  • Hammerspoon
  • whisper.cpp
  • ffmpeg
  • macOS dictation / fn-key preference changes

Press Enter to continue, or Ctrl-C to cancel.

BANNER
read -r

echo "→ Removing upscale-talk Hammerspoon config block..."
if [ -f ~/.hammerspoon/init.lua ]; then
  python3 - <<'PY'
import re, pathlib
p = pathlib.Path.home() / ".hammerspoon" / "init.lua"
text = p.read_text()
new_text = re.sub(r"\n*-- ===== upscale-talk =====.*\Z", "", text, flags=re.DOTALL)
new_text = re.sub(r"\n*-- upscale-talk:.*\Z", "", new_text, flags=re.DOTALL)
p.write_text(new_text)
print(f"   Cleaned {p}")
PY
fi

echo "→ Reloading Hammerspoon..."
open -g "hammerspoon://reload" 2>/dev/null || true

echo "→ Removing ~/upscale-talk/ (model + history)..."
rm -rf ~/upscale-talk

echo "→ Cleaning /tmp..."
rm -f /tmp/upscale-talk*.wav /tmp/upscale-talk-diag.log

cat <<'DONE'

✅ Uninstalled.

If you want to also remove Hammerspoon, whisper.cpp, or ffmpeg, run:
  brew uninstall --cask hammerspoon
  brew uninstall whisper-cpp
  brew uninstall ffmpeg

If you want to restore the macOS fn-key + dictation behaviour:
  defaults delete com.apple.HIToolbox AppleFnUsageType
  defaults delete com.apple.HIToolbox AppleDictationAutoEnable
  killall -HUP cfprefsd

You can close this window now.

DONE
echo "Press Enter to close..."
read -r
