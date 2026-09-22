#!/bin/bash
# doctor.sh — what is this upscale-talk install, and is it behaving?
#
# Read-only. Prints one block to paste back. Nothing is sent anywhere.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/scripts/doctor.sh)"
#
# This exists because "did the fix land?" has never been answerable. The
# start-at-login fix shipped on 2026-08-20 to eight people and was confirmed on
# one machine. An installer saying "Set to start automatically at login" is not
# evidence: install.sh only lints the plist, then swallows a failed bootstrap.
set -uo pipefail

RAW="https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main"
CFG="$HOME/.hammerspoon/init.lua"
DEST="$HOME/upscale-talk"
LABEL="com.upscale.upscale-talk-autostart"
MARKER="-- ===== upscale-talk ====="

row() { printf "%-14s %s\n" "$1" "$2"; }

echo "upscale-talk doctor - $(date '+%Y-%m-%d %H:%M %Z')"
row "name" "$(id -un)@$(scutil --get ComputerName 2>/dev/null || hostname -s)"

# ─── version ─────────────────────────────────────────────────────────────────
HAVE="$(sed -n 's/^local VERSION *= *"\(.*\)".*/\1/p' "$CFG" 2>/dev/null | head -1)"
WANT="$(curl -fsSL --max-time 8 "$RAW/VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$HAVE" ]; then row "version" "NOT INSTALLED (no VERSION in $CFG)"
elif [ -z "$WANT" ]; then row "version" "$HAVE   (could not reach GitHub to compare)"
elif [ "$HAVE" = "$WANT" ]; then row "version" "$HAVE   up to date"
else row "version" "$HAVE   (latest: $WANT)   OUT OF DATE"; fi

# ─── is the installed config actually the shipped one ────────────────────────
# Slice from the marker to EOF, which is the invariant both uninstallers regex
# against. Antoine's own install predates the marker, so fall back to the file.
blocksha() {
  local f="$1"
  if grep -q -- "$MARKER" "$f" 2>/dev/null; then
    sed -n "/$MARKER/,\$p" "$f" | shasum -a 256 | cut -c1-12
  else
    shasum -a 256 < "$f" | cut -c1-12
  fi
}
if [ -f "$CFG" ]; then
  MINE="$(blocksha "$CFG")"
  TMP="$(mktemp)"; curl -fsSL --max-time 8 "$RAW/init.lua" -o "$TMP" 2>/dev/null
  if [ -s "$TMP" ]; then
    THEIRS="$(blocksha "$TMP")"
    [ "$MINE" = "$THEIRS" ] && row "block sha" "$MINE   matches main" \
                            || row "block sha" "$MINE   (main: $THEIRS)   DIFFERENT"
  else
    row "block sha" "$MINE   (could not reach GitHub to compare)"
  fi
  rm -f "$TMP"
fi

# ─── start at login ──────────────────────────────────────────────────────────
# Read launchctl, never the installer's output. A "-" in the PID column is
# correct and expected: the agent runs `open -a Hammerspoon` once and exits.
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
  row "autostart" "registered ($LABEL)"
else
  row "autostart" "MISSING - this install loses the tool at the next restart"
fi

if pgrep -x Hammerspoon >/dev/null 2>&1; then
  row "hammerspoon" "running (pid $(pgrep -x Hammerspoon | head -1))"
else
  row "hammerspoon" "NOT RUNNING"
fi

# ─── meeting mode ────────────────────────────────────────────────────────────
if [ -f "$DEST/bin/capture-system.sh" ] && [ -f "$DEST/bin/capture-mic.sh" ]; then
  row "meeting mode" "installed"
elif [ -f "$DEST/bin/capture-system.sh" ]; then
  row "meeting mode" "HALF INSTALLED - re-run helpers/setup-meeting-mode.sh from the repo"
else
  row "meeting mode" "not installed (dictation only)"
fi

# ─── run-ons and unfinished meetings, straight off disk ──────────────────────
python3 - "$DEST/meetings" <<'PY'
import os, sys, time
root = sys.argv[1]
if not os.path.isdir(root):
    print("%-14s %s" % ("recordings", "no meetings folder")); raise SystemExit
HDR = 78          # fmt + LIST/INFO, measured on these files
def secs(p, bps):
    try: return max(0.0, (os.path.getsize(p) - HDR) / float(bps))
    except OSError: return None
runons, unfinished, bytes_unfinished = [], 0, 0
for name in sorted(os.listdir(root)):
    d = os.path.join(root, name)
    if not os.path.isdir(d): continue
    me, them = os.path.join(d, "me.wav"), os.path.join(d, "them.wav")
    m, t = secs(me, 64000), secs(them, 32000)        # me = 2ch, them = 1ch, both 16k
    # A healthy mic track is 10-27% SHORTER than the tap track, so a LONGER one
    # is unambiguous evidence the mic kept recording after the stop.
    if m and t and m > t * 1.1 + 60:
        runons.append((name, m, t))
    if (m or t) and not os.path.exists(os.path.join(d, "transcript.txt")):
        unfinished += 1
        bytes_unfinished += sum(os.path.getsize(os.path.join(d, f))
                                for f in os.listdir(d)
                                if f.endswith(".wav"))
if runons:
    first = True
    for name, m, t in runons:
        label = "run-ons" if first else ""
        print("%-14s %s  mic %.0fs  far side %.0fs  (+%.0fs after the stop)"
              % (label, name, m, t, m - t)); first = False
    print("%-14s %s" % ("", "that audio is whatever was in the room after you"))
    print("%-14s %s" % ("", "pressed stop. It is only on this Mac - have a look"))
    print("%-14s %s" % ("", "and delete anything you would rather not keep."))
else:
    print("%-14s %s" % ("run-ons", "none found"))
print("%-14s %d meetings with no transcript, %.1f GB"
      % ("unfinished", unfinished, bytes_unfinished / 1e9))
PY

echo
echo "Paste this whole block back to Antoine (antoine@up-scale.me)."
