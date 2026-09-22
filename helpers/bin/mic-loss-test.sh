#!/bin/bash
# mic-loss-test.sh [seconds] [avfoundation-index]
#
# Measures how much audio each mic capture backend actually delivers per second
# of wall clock. Needs no meeting, no Hammerspoon and no microphone permission
# beyond whatever the calling terminal already has.
#
# Why this exists: every meeting on disk has a me.wav that is 10-27% shorter than
# its them.wav, and the two tracks are merged by timestamp, so the mic drifts
# further out of alignment the longer the meeting runs. This script is the
# 20-second reproduction.
set -uo pipefail
SECS="${1:-20}"
DEV="${2:-1}"
FFMPEG="/opt/homebrew/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

report() {  # <label> <bytes> <bytes-per-second-of-audio>
  python3 -c "
b=$2; bps=$3; sec=b/float(bps); want=float($SECS)
print('  %-26s %6.2fs of %ss   %5.1f%% lost' % ('$1', sec, want, 100*(1-sec/want)))"
}

echo "mic-loss-test: ${SECS}s per backend, avfoundation index $DEV"
echo

"$FFMPEG" -loglevel error -f avfoundation -i ":$DEV" -ar 16000 -ac 2 \
          -t "$SECS" -f s16le "$TMP/ff.raw" 2>/dev/null
report "ffmpeg avfoundation" "$(stat -f%z "$TMP/ff.raw" 2>/dev/null || echo 0)" 64000

"$FFMPEG" -loglevel error -f avfoundation -i ":$DEV" \
          -t "$SECS" -f s16le "$TMP/ffnative.raw" 2>/dev/null
report "ffmpeg, no resample" "$(stat -f%z "$TMP/ffnative.raw" 2>/dev/null || echo 0)" 96000

if command -v rec >/dev/null 2>&1; then
  rec -q -c 2 -r 16000 -b 16 -t raw -e signed-integer "$TMP/sox.raw" \
      trim 0 "$SECS" 2>/dev/null
  report "sox/rec coreaudio" "$(stat -f%z "$TMP/sox.raw" 2>/dev/null || echo 0)" 64000
else
  echo "  sox/rec                    not installed (brew install sox)"
fi

echo
echo "The far side (them.wav) is captured by helpers/bin/audiotee, a Core Audio"
echo "process tap, and measures exact. Any loss above is the mic path only."
