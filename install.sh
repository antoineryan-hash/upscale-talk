#!/usr/bin/env bash
#
# upscale-talk one-line installer.
# Run it with:
#   curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/install.sh | bash
#
# Because this is fetched with curl (not opened from Finder), macOS does NOT
# quarantine it, so there is no "unverified developer" warning to fight.
#
# https://github.com/antoineryan-hash/upscale-talk
#
set -euo pipefail

RAW="https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main"

# When this script runs as `curl ... | bash`, its stdin IS the piped script,
# not your keyboard. So every interactive prompt reads from /dev/tty instead.
ask() { read -r "$@" </dev/tty; }

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

About 5 minutes total. Press Enter to begin (or Ctrl-C to bail out).
BANNER
ask

# ─── Prerequisites (Apple Silicon + Homebrew) ────────────────────────────────
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "❌ This tool requires an Apple Silicon Mac (M1 or newer). Detected: $(uname -m)."
  echo "   It won't run on Intel Macs. Nothing was installed."
  exit 1
fi

# brew may be installed but not yet on PATH (common right after a fresh install)
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
  read -r reply </dev/tty
  case "$reply" in
    [yY]*)
      echo ""
      echo "→ Installing Homebrew (this is the slow part - good time for a coffee)..."
      if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty; then
        echo ""
        echo "❌ Homebrew install didn't finish. Check your internet and run the whole line again."
        exit 1
      fi
      # Put brew on PATH now (this session) and for future sessions
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null || \
          printf '\neval "$(/opt/homebrew/bin/brew shellenv)"\n' >> "$HOME/.zprofile"
      fi
      ;;
    *)
      cat <<'SKIP'

No problem. Install Homebrew yourself by pasting this line, following its
prompts, then re-running the upscale-talk line:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

SKIP
      exit 1
      ;;
  esac
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "❌ Homebrew still isn't on PATH. Quit Terminal, open a fresh window, and run the upscale-talk line again."
  exit 1
fi

# ─── 1. Pre-flight conflict check (Voice Control + Hey Siri) ──────────────────
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
ask

# ─── 2. Homebrew dependencies ────────────────────────────────────────────────
echo ""
echo "→ Step 2/7: Installing Homebrew dependencies (Hammerspoon, whisper.cpp, ffmpeg)..."
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
brew list whisper-cpp        >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg             >/dev/null 2>&1 || brew install ffmpeg

# ─── 3. Set up directories + Whisper model ───────────────────────────────────
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

# ─── 4. Install Hammerspoon config ───────────────────────────────────────────
echo ""
echo "→ Step 4/7: Installing the engine config..."
mkdir -p ~/.hammerspoon

# Fetch the current init.lua straight from GitHub (no local files in a one-liner install)
INIT_LUA="/tmp/upscale-talk-init.lua"
curl -fsSL "$RAW/init.lua" -o "$INIT_LUA"

if [ -f ~/.hammerspoon/init.lua ] && grep -q "upscale-talk" ~/.hammerspoon/init.lua; then
  echo "  upscale-talk already in your Hammerspoon config - replacing it with the latest version..."
  # Strip any existing upscale-talk block, then re-append the fresh one.
  python3 - "$HOME/.hammerspoon/init.lua" "$INIT_LUA" <<'PY'
import sys
cfg_path, new_path = sys.argv[1], sys.argv[2]
cfg = open(cfg_path, encoding="utf-8").read()
# Remove a previously-appended "-- ===== upscale-talk =====" block if present,
# otherwise remove from the first upscale-talk header line to end of file.
marker = "\n\n-- ===== upscale-talk =====\n"
if marker in cfg:
    cfg = cfg[:cfg.index(marker)]
else:
    idx = cfg.find("-- upscale-talk:")
    if idx != -1:
        cfg = cfg[:idx]
cfg = cfg.rstrip()
new = open(new_path, encoding="utf-8").read()
sep = "\n\n-- ===== upscale-talk =====\n" if cfg.strip() else ""
open(cfg_path, "w", encoding="utf-8").write(cfg + sep + new)
PY
  echo "  Updated ~/.hammerspoon/init.lua to the latest upscale-talk."
else
  if [ -f ~/.hammerspoon/init.lua ] && [ -s ~/.hammerspoon/init.lua ]; then
    printf "\n\n-- ===== upscale-talk =====\n" >> ~/.hammerspoon/init.lua
  fi
  cat "$INIT_LUA" >> ~/.hammerspoon/init.lua
  echo "  Config installed at ~/.hammerspoon/init.lua"
fi

# ─── 5. macOS defaults that prevent conflicts ────────────────────────────────
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
  osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
open -a Hammerspoon
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
ask

echo ""
echo "→ Permission 2 of 3: Input Monitoring (so the app can hear the fn key)"
echo "  Opening Settings > Privacy & Security > Input Monitoring..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
echo ""
echo "  ACTION:"
echo "    - If Hammerspoon is ALREADY in the list, toggle it ON."
echo "    - If Hammerspoon is NOT in the list yet:"
echo "        - Click the + button below the list"
echo "        - In the file picker, press Cmd+Shift+G and paste:"
echo "          /Applications/Hammerspoon.app"
echo "        - Press Open, then toggle Hammerspoon ON."
echo ""
echo "  macOS will ask to quit & reopen Hammerspoon. Click 'Quit & Reopen'."
echo "  When done, press Enter here."
ask

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
ask

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
ask

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
  • On AirPods/Bluetooth it records from your built-in mic instead (Bluetooth
    mics often deliver silence). If a take ever comes back empty you'll see a
    "No audio captured" note rather than garbage text.
  • Privacy: audio never leaves your Mac. No cloud, no API, no telemetry.
    The Whisper model runs on-device.

If something stops working:
  • Click the 🔨 hammer icon in your menu bar > Reload Config.
  • If still broken, fully quit Hammerspoon from the same menu, then
    re-open it from /Applications/Hammerspoon.app.

Want to remove it later? Paste this in Terminal:
  curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/uninstall.sh | bash

You can close this window now.
──────────────────────────────────────────────────────────────────

DONE
