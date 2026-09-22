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

OUT="${1:?usage: capture-system.sh <out.wav> [max-seconds] [heartbeat-file]}"
MAXSEC="${2:-0}"
HB="${3:-}"
TAP_LOG="${OUT%.wav}.tap.log"
HERE="$(cd "$(dirname "$0")" && pwd)"
AUDIOTEE="$HERE/audiotee"
FFMPEG="/opt/homebrew/bin/ffmpeg"

FIFO="$(mktemp -u).pcm"
mkfifo "$FIFO"

# ffmpeg wraps the raw s16le/16k/mono stream from the tap into a real WAV.
"$FFMPEG" -loglevel error -f s16le -ar 16000 -ac 1 -i "$FIFO" -c:a pcm_s16le -y "$OUT" &
FF_PID=$!

# The tap streams system audio as raw PCM into the fifo.
"$AUDIOTEE" --sample-rate 16000 2>"$TAP_LOG" > "$FIFO" &
AT_PID=$!

cleanup() {
  [ -n "${GUARD_PID:-}" ] && kill -TERM "$GUARD_PID" 2>/dev/null
  kill -TERM "$AT_PID" 2>/dev/null   # stop the tap -> EOF on the fifo
  wait "$FF_PID" 2>/dev/null          # let ffmpeg finalise a valid WAV
  rm -f "$FIFO"
  exit 0
}
trap cleanup TERM INT

# ─── guard: bound the capture without depending on Hammerspoon ───────────────
# Two limits, both enforced here rather than in Lua, because an hs.timer dies
# with the process that owns the fn event tap. If stopMeeting() never runs -
# the tap is dead, Hammerspoon crashed, or the stop path threw - nothing else
# stops this. Marc Starrett reported a 36 minute run-on on 2026-09-03.
#
#   max-seconds     hard ceiling on one recording
#   heartbeat-file  Hammerspoon touches it while a meeting is live; if it goes
#                   stale we stop ourselves. Only enforced once the file has
#                   been seen, so an older init.lua that writes none behaves
#                   exactly as before.
#
# Keep in sync with capture-mic.sh.
if [ "$MAXSEC" -gt 0 ] 2>/dev/null || [ -n "$HB" ]; then
  MAIN=$$
  (
    START=$(date +%s)
    SEEN_HB=0
    while kill -0 "$MAIN" 2>/dev/null; do
      sleep 15
      NOW=$(date +%s)
      if [ "$MAXSEC" -gt 0 ] 2>/dev/null && [ $((NOW - START)) -ge "$MAXSEC" ]; then
        kill -TERM "$MAIN" 2>/dev/null; exit 0
      fi
      if [ -n "$HB" ] && [ -f "$HB" ]; then
        SEEN_HB=1
        AGE=$(( NOW - $(stat -f %m "$HB" 2>/dev/null || echo "$NOW") ))
        if [ "$AGE" -gt 90 ]; then kill -TERM "$MAIN" 2>/dev/null; exit 0; fi
      fi
    done
  ) &
  GUARD_PID=$!
fi

wait "$AT_PID"   # normal path: tap exits on its own (rare) -> finalise
cleanup
