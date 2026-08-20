#!/usr/bin/env bash
#
# upscale-talk — make it survive a reboot.
#
# The bug this fixes: install.sh launched Hammerspoon (the engine upscale-talk
# runs on) but never registered it to start at login. So the tool worked
# perfectly right up until the user's next restart — a macOS update, a flat
# battery — and then silently never came back. Nothing looked broken: the
# config, the model and all three permissions were still in place. There was
# just nothing running. Found 2026-08-20 on Lachlan Waugh's Mac after the
# macOS 26.6.2 update; 404 transcriptions intact, zero since the reboot.
#
# Safe to run repeatedly. Changes nothing else about the install.
#
set -euo pipefail

LABEL="com.upscale.upscale-talk-autostart"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/Hammerspoon.app"

echo ""
echo "→ upscale-talk: making it start automatically at login"
echo ""

if [ ! -d "$APP" ]; then
  echo "  ✗ Hammerspoon isn't installed at $APP."
  echo "    That means upscale-talk isn't installed either. Install it first:"
  echo '    bash -c "$(curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/install.sh)"'
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>Hammerspoon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLISTEOF

# Fail loudly rather than registering a plist macOS will silently reject.
plutil -lint "$PLIST" >/dev/null || { echo "  ✗ Generated plist is invalid."; exit 1; }

# bootout first so re-running picks up any change (ignore "not loaded").
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"

echo "  ✓ Registered. Hammerspoon will now start every time you log in."
echo "    (Remove any time: launchctl bootout gui/\$UID/$LABEL && rm $PLIST)"
echo ""

# RunAtLoad starts it now too, but confirm rather than assume.
sleep 2
if pgrep -x Hammerspoon >/dev/null; then
  echo "  ✓ Hammerspoon is running now."
else
  echo "  → Starting Hammerspoon..."
  open -a Hammerspoon
  sleep 3
  if pgrep -x Hammerspoon >/dev/null; then
    echo "  ✓ Hammerspoon is running now."
  else
    echo "  ✗ Hammerspoon did not start. Open $APP manually and check for an error."
    exit 1
  fi
fi

echo ""
echo "──────────────────────────────────────────────────────────────"
echo "Done. Test it: hold fn, wait for the RED dot, speak, release."
echo "The 🎤 in your menu bar shows your recent transcriptions."
echo "──────────────────────────────────────────────────────────────"
echo ""
