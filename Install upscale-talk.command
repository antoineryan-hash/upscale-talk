#!/usr/bin/env bash
#
# Install upscale-talk - double-clickable from Finder.
# https://github.com/antoineryan-hash/upscale-talk
#
set -euo pipefail

# Friendly intro
cat <<'BANNER'

┌─────────────────────────────────────────────────────┐
│                                                     │
│  upscale-talk - voice-to-text for your Mac          │
│  Free, local, no cloud, no subscription             │
│                                                     │
└─────────────────────────────────────────────────────┘

This installer will:
  1. Check for conflicts (Voice Control + Hey Siri must be off)
  2. Install three Homebrew packages (Hammerspoon, whisper.cpp, ffmpeg)
  3. Download a 547 MB Whisper model
  4. Set up ~/upscale-talk/ for transcription history
  5. Disable macOS built-in dictation + fn-emoji-picker (avoids conflict)
  6. Walk you through three macOS permissions
  7. Run a live smoke test so you know it actually works

About 5 minutes total. Press Enter to begin.
BANNER
read -r

# ─── Prerequisites (Apple Silicon + Homebrew) ────────────────────────────────
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ This tool requires an Apple Silicon Mac (M1 or newer). Detected: $(uname -m)."
  echo "   It won't run on Intel Macs. Nothing was installed."
  echo "Press Enter to close..."; read -r; exit 1
fi

command -v brew >/dev/null 2>&1 || { [ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"; }

if ! command -v brew >/dev/null 2>&1; then
  cat <<'NOBREW'

→ First: Homebrew (required, and not installed yet)

upscale-talk installs its three parts (Hammerspoon, whisper.cpp, ffmpeg) using
Homebrew - Apple's standard, free package manager. Your Mac doesn't have it yet.

I can install it for you right now. Two things to expect:
  - It downloads Apple's Command Line Tools. On a fresh Mac this can take
    5-20 minutes depending on your internet. Just let it run.
  - It asks for your Mac login password once. You won't see characters as you
    type it - that's normal. Type it and press Enter.

NOBREW
  printf "Install Homebrew now? [y/N] "
  read -r reply
  case "$reply" in
    [yY]*)
      echo ""
      echo "→ Installing Homebrew (this is the slow part - good time for a coffee)..."
      if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
        echo ""
        echo "❌ Homebrew install didn't finish. Check your internet and run this installer again."
        echo "Press Enter to close..."; read -r; exit 1
      fi
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
          printf '\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >> "$HOME/.zprofile"
      fi
      ;;
    *)
      cat <<'SKIP'

No problem. Install Homebrew yourself by pasting this line into Terminal,
following its prompts, then run this installer again:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

SKIP
      echo "Press Enter to close..."; read -r; exit 1
      ;;
  esac
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew still isn't on PATH. Quit Terminal, open a fresh window, and run this installer again."
  echo "Press Enter to close..."; read -r; exit 1
fi

# ─── 0. Pre-flight conflict check (Voice Control + Hey Siri) ─────────────────
cat <<'PREFLIGHT'

→ Step 1/7: Pre-flight conflict check

Two macOS features can compete with upscale-talk for the microphone. If
either is on, you will get two mic indicators in your menu bar and weird
behaviour. Both need to be off BEFORE we install.

  (a) Voice Control - Accessibility's hands-free Mac control. If it's on,
      you'll see a blue waveform icon in your menu bar.
      Setting: System Settings > Accessibility > Voice Control > OFF

  (b) Hey Siri (also called "Listen for") - always-listening Siri wake word.
      Setting: System Settings > Apple Intelligence & Siri > Listen for... > OFF

If you're not sure, check your menu bar right now. If you see EITHER a blue
waveform icon OR Siri "actively listening," one of those is on.

Press Enter once both are off (or you've confirmed they were already off).
PREFLIGHT
read -r

# ─── 1. Homebrew dependencies ────────────────────────────────────────────────
echo ""
echo "→ Step 2/7: Installing Homebrew dependencies (Hammerspoon, whisper.cpp, ffmpeg)..."
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
brew list whisper-cpp        >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg             >/dev/null 2>&1 || brew install ffmpeg

# ─── 2. Set up directories + Whisper model ───────────────────────────────────
echo ""
echo "→ Step 3/7: Setting up ~/upscale-talk/ and Whisper model..."
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
  echo "  Downloading Whisper model (547 MB - about 1-2 minutes on a normal connection)..."
  curl -fL --progress-bar -o "$OUR_MODEL" "$MODEL_URL"
fi

# ─── 3. Install Hammerspoon config ───────────────────────────────────────────
echo ""
echo "→ Step 4/7: Installing the engine config..."
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
echo "→ Step 5/7: Disabling macOS Dictation + fn-emoji-picker..."
defaults write com.apple.HIToolbox AppleDictationAutoEnable -bool false
defaults write com.apple.HIToolbox AppleFnUsageType -int 0
killall -HUP cfprefsd 2>/dev/null || true
echo "  Done. (Reversible: 'defaults delete com.apple.HIToolbox AppleDictationAutoEnable' and 'defaults delete com.apple.HIToolbox AppleFnUsageType')"

# ─── 6. Launch Hammerspoon + walk through permissions ────────────────────────
echo ""
echo "→ Step 6/7: Launching the engine and walking through 3 macOS permissions..."
if pgrep -x Hammerspoon >/dev/null; then
  open -g "hammerspoon://reload" 2>/dev/null || true
else
  open -a Hammerspoon
fi
sleep 2

cat <<'PERMS'

──────────────────────────────────────────────────────────────────
upscale-talk runs on top of Hammerspoon (an open-source Mac
automation engine). Hammerspoon needs three macOS permissions
to do its job. I'll open each pane and you toggle one switch.
──────────────────────────────────────────────────────────────────

PERMS

echo "→ Permission 1 of 3: Accessibility (so the app can paste text into any window)"
echo "  Opening Settings > Privacy & Security > Accessibility..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
echo ""
echo "  ACTION: Find Hammerspoon in the list, toggle it ON."
echo "          (If you see a lock icon, click it and authenticate first.)"
echo ""
echo "  When the toggle is ON, come back here and press Enter."
read -r

echo ""
echo "→ Permission 2 of 3: Input Monitoring (so the app can hear the fn key)"
echo "  Opening Settings > Privacy & Security > Input Monitoring..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
echo ""
echo "  ACTION:"
echo "    • If Hammerspoon is ALREADY in the list, toggle it ON."
echo "    • If Hammerspoon is NOT in the list yet:"
echo "        - Click the + button below the list"
echo "        - In the file picker, press Cmd+Shift+G and paste:"
echo "          /Applications/Hammerspoon.app"
echo "        - Press Open, then toggle Hammerspoon ON."
echo ""
echo "  macOS will ask to quit & reopen Hammerspoon. Click 'Quit & Reopen'."
echo "  When done, press Enter here."
read -r

# Hammerspoon was quit by macOS in the prior step. Restart it.
open -a Hammerspoon
sleep 2

echo ""
echo "→ Permission 3 of 3: Microphone (so the app can record your voice)"
echo "  Opening Settings > Privacy & Security > Microphone..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
echo ""
echo "  ACTION: Toggle Hammerspoon ON."
echo "  (If Hammerspoon isn't in the list yet, that's fine. macOS will"
echo "  prompt you the first time you actually dictate, and you can grant"
echo "  it then. We'll test in the next step.)"
echo ""
echo "  Press Enter to continue."
read -r

# ─── 7. Live smoke test ──────────────────────────────────────────────────────
cat <<'TEST'

──────────────────────────────────────────────────────────────────
→ Step 7/7: Live smoke test

Let's confirm it actually works. Here is the muscle memory:

  HOLD the fn key (the bottom-left key with the globe 🌐 icon).
  Wait half a second for a RED DOT to appear in the top-right of your screen.
  THEN speak.
  THEN release the fn key.
  A GREEN DOT briefly appears while it transcribes.
  Then your text pastes wherever your cursor is.

  Important: HOLD the key, don't tap it. And wait for the red dot before
  you speak. If you talk before the red dot appears, the first word gets
  cut off. (Typical wait: a few hundred ms on a cold mic, near-instant
  once it's warm.)

──────────────────────────────────────────────────────────────────

Now do this:
  1. Click into this Terminal window so the cursor flashes at the bottom.
  2. Hold fn. Wait for the red dot. Say: "this is a test of upscale talk".
  3. Release fn.
  4. The transcribed text should appear here within a couple of seconds.

If it worked, press Enter to finish. If nothing happened or it misbehaved,
press Enter anyway and check the troubleshooting notes that follow.

TEST
read -r

# ─── Done ────────────────────────────────────────────────────────────────────
cat <<'DONE'

──────────────────────────────────────────────────────────────────
✅ Install complete!

How to use it day-to-day:
  • Hold the fn key (bottom-left globe). Wait for the RED dot. Speak. Release.
    GREEN dot = transcribing. Text pastes at your cursor.
  • Double-tap fn to LOCK recording on (hands-free for long dictations).
    Tap fn once to stop and transcribe.
  • Click the 🎤 in your menu bar (top-right) to see your last 20
    transcriptions. Click any to copy it back to the clipboard.
  • Every transcription is saved at ~/upscale-talk/history/ as a plain
    text file with a timestamp. Never auto-deleted. Browse anytime in Finder.

What's normal that might surprise you:
  • First press after 5+ min idle: a couple hundred ms before the red dot
    appears. This is the audio device cold-start. After that, near-instant.
  • If you talk BEFORE the red dot, the first word gets cut. Wait for the dot.
  • Privacy: audio never leaves your Mac. No cloud, no API, no telemetry.
    The Whisper model runs on-device.

If something stops working:
  • Click the 🔨 hammer icon in your menu bar > Reload Config.
  • If still broken, fully quit Hammerspoon from the same menu, then
    re-open it from /Applications/Hammerspoon.app.

Want to remove it later? Double-click "Uninstall upscale-talk.command".

You can close this window now.
──────────────────────────────────────────────────────────────────

DONE
echo "Press Enter to close..."
read -r
