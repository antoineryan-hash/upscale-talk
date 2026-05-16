#!/usr/bin/env bash
#
# upscale-talk installer
# https://github.com/antoineryan-hash/upscale-talk
#
# Hold fn → speak → release → text pastes at cursor.
# Free, local-only Whisper push-to-talk dictation for macOS.
#
# Requires Apple Silicon (M1+), macOS 13+, Homebrew.
#
set -euo pipefail

REPO_OWNER="antoineryan-hash"
REPO_NAME="upscale-talk"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"

echo "→ upscale-talk installer"
echo

# 1. Check prerequisites
if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew not found. Install from https://brew.sh first, then re-run."
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ This tool is built for Apple Silicon (M1+). Detected arch: $(uname -m)."
  exit 1
fi

# 2. Install Homebrew dependencies
echo "→ Installing Homebrew dependencies (Hammerspoon, whisper.cpp, ffmpeg)..."
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
brew list whisper-cpp        >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg             >/dev/null 2>&1 || brew install ffmpeg

# 3. Set up our directory + Whisper model
mkdir -p ~/.upscale-talk/models
OUR_MODEL="$HOME/.upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
VOICEINK_MODEL="$HOME/Library/Application Support/com.prakashjoshipax.VoiceInk/WhisperModels/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

if [ -f "$OUR_MODEL" ]; then
  echo "→ Model already present at $OUR_MODEL, skipping."
elif [ -f "$VOICEINK_MODEL" ]; then
  echo "→ Reusing VoiceInk's downloaded model (saves 547 MB redownload)..."
  cp "$VOICEINK_MODEL" "$OUR_MODEL"
else
  echo "→ Downloading large-v3-turbo Q5_0 (~547 MB)..."
  curl -fL -o "$OUR_MODEL" "$MODEL_URL"
fi
echo "   Model size: $(du -h "$OUR_MODEL" | cut -f1)"

# 4. Install Hammerspoon config (additive — preserves any existing config)
mkdir -p ~/.hammerspoon
if [ -f ~/.hammerspoon/init.lua ] && grep -q "upscale-talk" ~/.hammerspoon/init.lua; then
  echo "→ Hammerspoon config already has upscale-talk, skipping."
else
  echo "→ Installing Hammerspoon config (appended to any existing init.lua)..."
  if [ -f ~/.hammerspoon/init.lua ]; then
    printf "\n\n-- ===== upscale-talk =====\n" >> ~/.hammerspoon/init.lua
  fi
  curl -fsSL "$REPO_RAW/init.lua" >> ~/.hammerspoon/init.lua
fi

# 5. Disable macOS built-in dictation (avoids fn-key conflict)
echo "→ Disabling macOS built-in dictation..."
defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool false

# 5b. Set fn-key behavior to "Do Nothing" so it doesn't pop the emoji picker
# every time you tap it for dictation. Without this, double-tapping fn pops
# the emoji panel which steals focus from your text field.
echo "→ Disabling macOS fn-key emoji-picker behavior..."
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
killall -HUP cfprefsd 2>/dev/null || true

# 6. Launch Hammerspoon (or reload if already running)
echo "→ Launching Hammerspoon..."
if pgrep -x Hammerspoon >/dev/null; then
  open -g "hammerspoon://reload" 2>/dev/null || true
else
  open -a Hammerspoon
fi

cat <<'EOF'

✅ Install complete.

────────────────────────────────────────────────────────────
Next steps (one-time, ~30 seconds):

  1. System Settings → Privacy & Security → Accessibility → enable Hammerspoon
  2. System Settings → Privacy & Security → Input Monitoring → enable Hammerspoon
  3. System Settings → Privacy & Security → Microphone → enable Hammerspoon
     (if not auto-prompted on first dictation)

Optional but recommended:

  System Settings → Keyboard → Press 🌐 key to: Do Nothing
  (prevents the emoji picker briefly flashing on fn-press)

────────────────────────────────────────────────────────────

Test it:

  Open any text field, hold fn, speak, release. Text pastes at cursor.

Troubleshooting:

  Hammerspoon console (in menubar): hs.reload() to pick up config changes.
  Repo: https://github.com/antoineryan-hash/upscale-talk

EOF
