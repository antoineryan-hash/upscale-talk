#!/usr/bin/env bash
#
# Install upscale-talk — double-clickable from Finder.
# https://github.com/antoineryan-hash/upscale-talk
#
set -euo pipefail

# Friendly intro
cat <<'BANNER'

┌─────────────────────────────────────────────────────┐
│                                                     │
│  upscale-talk — voice-to-text for your Mac          │
│  Free, local, no cloud, no subscription             │
│                                                     │
└─────────────────────────────────────────────────────┘

This installer will:
  1. Install three Homebrew packages (Hammerspoon, whisper.cpp, ffmpeg)
  2. Download a 547 MB Whisper model
  3. Set up ~/upscale-talk/ for transcription history
  4. Disable macOS built-in dictation + fn-emoji-picker (avoids conflict)
  5. Open System Settings so you can grant Hammerspoon 3 permissions

The whole thing takes ~5 minutes. Press Enter to begin.
BANNER
read -r

# ─── Prerequisites ───────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew not found. Install from https://brew.sh first, then re-run this script."
  echo "Press Enter to close..."
  read -r
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ This tool requires Apple Silicon (M1+). Detected arch: $(uname -m)."
  echo "Press Enter to close..."
  read -r
  exit 1
fi

# ─── 1. Homebrew dependencies ────────────────────────────────────────────────
echo ""
echo "→ Step 1/5: Installing Homebrew dependencies..."
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
brew list whisper-cpp        >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg             >/dev/null 2>&1 || brew install ffmpeg

# ─── 2. Set up directories + Whisper model ───────────────────────────────────
echo ""
echo "→ Step 2/5: Setting up ~/upscale-talk/ and Whisper model..."
mkdir -p ~/upscale-talk/models ~/upscale-talk/history

OUR_MODEL="$HOME/upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
VOICEINK_MODEL="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

if [ -f "$OUR_MODEL" ]; then
  echo "  Model already present, skipping download."
elif [ -f "$VOICEINK_MODEL" ]; then
  echo "  Reusing VoiceInk's existing model (saves 547 MB redownload)."
  cp "$VOICEINK_MODEL" "$OUR_MODEL"
else
  echo "  Downloading Whisper model (547 MB — about 1-2 minutes on a normal connection)..."
  curl -fL --progress-bar -o "$OUR_MODEL" "$MODEL_URL"
fi

# ─── 3. Install Hammerspoon config ───────────────────────────────────────────
echo ""
echo "→ Step 3/5: Installing Hammerspoon config..."
mkdir -p ~/.hammerspoon

# Find init.lua next to this script (bundled in the zip)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INIT_LUA="$SCRIPT_DIR/files/init.lua"
if [ ! -f "$INIT_LUA" ]; then
  # Fallback: maybe the user ran us from a non-bundled location, try GitHub
  INIT_LUA_URL="https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/init.lua"
  echo "  (init.lua not next to this script, fetching from GitHub instead)"
  INIT_LUA="/tmp/upscale-talk-init.lua"
  curl -fsSL "$INIT_LUA_URL" -o "$INIT_LUA"
fi

if [ -f ~/.hammerspoon/init.lua ] && grep -q "upscale-talk" ~/.hammerspoon/init.lua; then
  echo "  upscale-talk already in your Hammerspoon config, skipping append."
else
  if [ -f ~/.hammerspoon/init.lua ]; then
    printf "\n\n-- ===== upscale-talk =====\n" >> ~/.hammerspoon/init.lua
  fi
  cat "$INIT_LUA" >> ~/.hammerspoon/init.lua
  echo "  Config installed at ~/.hammerspoon/init.lua"
fi

# ─── 4. macOS defaults that prevent conflicts ────────────────────────────────
echo ""
echo "→ Step 4/5: Disabling macOS dictation + fn-emoji-picker (these conflict with upscale-talk)..."
defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool false
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
killall -HUP cfprefsd 2>/dev/null || true
echo "  Done. (Reversible: 'defaults delete com.apple.HIToolbox AppleDictationAutoEnable' and 'defaults delete com.apple.HIToolbox AppleFnUsageType')"

# ─── 5. Launch Hammerspoon + walk through permissions ────────────────────────
echo ""
echo "→ Step 5/5: Launching Hammerspoon and walking through permissions..."
if pgrep -x Hammerspoon >/dev/null; then
  open -g "hammerspoon://reload" 2>/dev/null || true
else
  open -a Hammerspoon
fi
sleep 2

cat <<'PERMS'

──────────────────────────────────────────────────────────────────
Hammerspoon needs three permissions to do its job. I'll open each
System Settings pane for you. For each one, follow the instruction
then come back here and press Enter to move to the next.
──────────────────────────────────────────────────────────────────

PERMS

echo "→ Permission 1/3: Accessibility (lets the app paste text into any window)"
echo "  Opening System Settings → Privacy & Security → Accessibility..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo ""
echo "  ACTION REQUIRED: Toggle Hammerspoon ON in the list (you may need to unlock the lock icon first)."
echo "  When done, come back here and press Enter."
read -r

echo ""
echo "→ Permission 2/3: Input Monitoring (lets the app listen for the fn key)"
echo "  Opening System Settings → Privacy & Security → Input Monitoring..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
echo ""
echo "  ACTION REQUIRED:"
echo "    a) Click the '+' button at the bottom of the list"
echo "    b) Navigate to /Applications and select Hammerspoon.app"
echo "    c) Toggle the switch ON for Hammerspoon"
echo "    d) macOS will ask to quit & reopen Hammerspoon — click 'Quit & Reopen'"
echo "  When done, come back here and press Enter."
read -r

# Hammerspoon was quit, restart it
open -a Hammerspoon
sleep 2

echo ""
echo "→ Permission 3/3: Microphone (lets the app record your voice)"
echo "  Opening System Settings → Privacy & Security → Microphone..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
echo ""
echo "  ACTION REQUIRED: Toggle Hammerspoon ON. (If Hammerspoon isn't in the list yet,"
echo "  it'll auto-appear and prompt the first time you dictate — that's also fine.)"
echo "  When done, come back here and press Enter."
read -r

# ─── Done ────────────────────────────────────────────────────────────────────
cat <<'DONE'

──────────────────────────────────────────────────────────────────
✅ Install complete!

How to use:
  • Hold fn (bottom-left globe key), speak, release. Text pastes at your cursor.
  • Double-tap fn to lock recording on (hands-free). Tap fn again to stop.
  • 🎤 menu bar icon: see your last 20 transcriptions, click to copy any.
  • All transcriptions saved in ~/upscale-talk/history/ (text files, never deleted).

Notes:
  • First dictation after a 5+ minute idle will take ~360 ms before the red dot
    appears (mic cold-start). Subsequent dictations are near-instant.
  • Privacy: audio never leaves your Mac. No cloud, no API calls.

Want to remove it later? Double-click "Uninstall upscale-talk.command" in this folder.

You can close this window now.
──────────────────────────────────────────────────────────────────

DONE
echo "Press Enter to close..."
read -r
