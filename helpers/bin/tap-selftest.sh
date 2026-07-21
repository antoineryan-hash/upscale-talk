#!/bin/bash
# tap-selftest.sh — one-time check that system-audio capture works on THIS Mac.
#
# Run it in YOUR OWN Terminal (not via an agent) so the macOS permission prompt
# attributes to Terminal and you can click Allow:
#
#     ~/Projects/upscale-talk/helpers/bin/tap-selftest.sh
#
# It captures ~8 s of whatever is playing out of your speakers/AirPods, then
# tells you whether real audio was captured. START A YOUTUBE VIDEO OR MUSIC
# first (or right after you hit enter).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FFMPEG="/opt/homebrew/bin/ffmpeg"
OUT="/tmp/upscale-tap-selftest.wav"

echo ""
echo ">>> Play a YouTube video or some music NOW (through your normal output)."
echo ">>> Capturing 8 seconds of system audio..."
echo ""

# 256000 bytes = 8 s @ 16 kHz mono s16le; head -c bounds the stream, then the
# tap gets SIGPIPE and exits. First run pops the Audio-Recording permission.
"$HERE/audiotee" --sample-rate 16000 2>/dev/null \
  | head -c 256000 \
  | "$FFMPEG" -loglevel error -f s16le -ar 16000 -ac 1 -i - -c:a pcm_s16le -y "$OUT"

LVL=$("$FFMPEG" -i "$OUT" -af volumedetect -f null - 2>&1 | awk -F': ' '/max_volume/{print $2}')
VERDICT=$(echo "${LVL:--91 dB}" | awk '{v=$1+0; print (v > -80) ? "PASS" : "FAIL"}')

echo ""
echo "Captured -> $OUT"
echo "Max volume: ${LVL:-<none>}"
if [ "$VERDICT" = "PASS" ]; then
  echo "✅ PASS — the tap captured real audio over your current output device."
else
  echo "❌ FAIL — silent capture. Either nothing was playing, or the"
  echo "   'Audio Recording' permission isn't granted yet:"
  echo "   System Settings > Privacy & Security > Screen & System Audio Recording"
  echo "   (allow Terminal for this test; Hammerspoon for the real tool), then re-run."
fi
echo ""
