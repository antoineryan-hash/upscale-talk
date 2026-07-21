#!/bin/bash
# capture-system.sh <out.wav>
#
# Captures the Mac's SYSTEM OUTPUT audio (everything you hear — the far side of a
# Zoom/Meet call, etc.) to a 16 kHz mono WAV, using a Core Audio process tap
# (the vendored `audiotee` helper). Does NOT alter your audio routing: you keep
# hearing the meeting normally while it records.
#
# Used by upscale-talk meeting mode. Meant to be started and then terminated
# (SIGTERM) when the meeting ends — it finalises the WAV cleanly on stop.
#
# Requires the one-time macOS "Audio Recording" permission for the process that
# launches it (Hammerspoon in normal use). Without it the tap streams silence.
set -uo pipefail

OUT="${1:?usage: capture-system.sh <out.wav>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIOTEE="$HERE/audiotee"
FFMPEG="/opt/homebrew/bin/ffmpeg"

FIFO="$(mktemp -u).pcm"
mkfifo "$FIFO"

# ffmpeg wraps the raw s16le/16k/mono stream from the tap into a real WAV.
"$FFMPEG" -loglevel error -f s16le -ar 16000 -ac 1 -i "$FIFO" -c:a pcm_s16le -y "$OUT" &
FF_PID=$!

# The tap streams system audio as raw PCM into the fifo.
"$AUDIOTEE" --sample-rate 16000 2>/dev/null > "$FIFO" &
AT_PID=$!

cleanup() {
  kill -TERM "$AT_PID" 2>/dev/null   # stop the tap -> EOF on the fifo
  wait "$FF_PID" 2>/dev/null          # let ffmpeg finalise a valid WAV
  rm -f "$FIFO"
  exit 0
}
trap cleanup TERM INT

wait "$AT_PID"   # normal path: tap exits on its own (rare) -> finalise
cleanup
