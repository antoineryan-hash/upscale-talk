#!/bin/bash
# capture-mic.sh <out.wav> <avfoundation-input-index> [max-seconds] [heartbeat-file]
#
# Captures YOUR MIC to a 16 kHz 2-channel WAV for upscale-talk meeting mode.
#
# Why a wrapper instead of one ffmpeg writing the file directly:
#
#   1. ffmpeg IGNORES SIGTERM while it is blocked reading from avfoundation, so
#      the only reliable stop is SIGKILL — and a SIGKILLed writer never patches
#      the RIFF size back into its own header. Every me.wav on disk before this
#      change carries a placeholder size, which is why meeting_transcribe.py and
#      calendar_roster.py both had to grow header workarounds (3854c2b).
#      Here the CAPTURE and the WRITER are two processes joined by a fifo. Kill
#      the capture however you like; the writer still sees EOF and finalises a
#      valid WAV. This is exactly the shape capture-system.sh already uses, and
#      it is why them.wav has always been correct while me.wav has not.
#
#   2. -t is enforced inside ffmpeg, so the recording is bounded even if
#      Hammerspoon dies. A Lua timer cannot do that: it dies with the process
#      that owns the event tap.
#
#   3. The heartbeat file gives a second, shorter bound. Hammerspoon touches it
#      while a meeting is running; if it goes stale the capture stops itself.
#      A meeting can no longer run on for 36 minutes because the stop path never
#      ran (reported by Marc Starrett, 2026-09-03).
#
# Keep the guard block below in sync with capture-system.sh.
set -uo pipefail

OUT="${1:?usage: capture-mic.sh <out.wav> <avfoundation-input> [max-seconds] [heartbeat-file]}"
DEV="${2:?usage: capture-mic.sh <out.wav> <avfoundation-input> [max-seconds] [heartbeat-file]}"
MAXSEC="${3:-0}"
HB="${4:-}"

MIC_LOG="${OUT%.wav}.mic.log"
FFMPEG="/opt/homebrew/bin/ffmpeg"
[ -x "$FFMPEG" ] || FFMPEG="$(command -v ffmpeg)"

# ─── let go of Hammerspoon's pipes before anything else ──────────────────────
# Same reason as capture-system.sh: Hammerspoon reads this script's stdout and
# stderr to EOF on its MAIN THREAD when it exits, so any child still holding
# them (a stuck writer, the guard's `sleep 15`) freezes the whole app. That is
# what happened on 2026-09-28. Nothing started below can hold them now.
exec </dev/null >>"${OUT%.wav}.wrapper.log" 2>&1
log() { printf '%s capture-mic: %s\n' "$(date '+%H:%M:%S')" "$*"; }

# Installed before any child exists, so a stop in the first milliseconds still
# cleans up instead of killing the script mid-launch.
FF_PID=""; MIC_PID=""; GUARD_PID=""; FIFO=""; STOPPING=0

# Wait up to $2 tenths of a second for pid $1 to exit. Returns 1 if still alive.
wait_gone() {
  local n=0
  while kill -0 "$1" 2>/dev/null; do
    [ "$n" -ge "$2" ] && return 1
    sleep 0.1; n=$((n + 1))
  done
  return 0
}

cleanup() {
  [ "$STOPPING" = 1 ] && return
  STOPPING=1
  if [ -n "$GUARD_PID" ]; then
    pkill -TERM -P "$GUARD_PID" 2>/dev/null   # its sleep
    kill -TERM "$GUARD_PID" 2>/dev/null
  fi
  if [ -n "$MIC_PID" ]; then
    kill -TERM "$MIC_PID" 2>/dev/null                          # polite first, in case it is between reads
    wait_gone "$MIC_PID" 3 || kill -9 "$MIC_PID" 2>/dev/null   # it ignores SIGTERM on avfoundation
  fi
  if [ -n "$FF_PID" ]; then
    # Let the writer finalise a valid WAV, but never wait forever. Everything
    # here must finish inside init.lua's 2 s escalation.
    if ! wait_gone "$FF_PID" 8; then
      log "writer still waiting 0.8 s after the capture stopped - killed it; me.wav may be incomplete"
      kill -9 "$FF_PID" 2>/dev/null
    fi
    wait "$FF_PID" 2>/dev/null
  fi
  pkill -9 -P $$ 2>/dev/null   # a child started just as the stop landed, before its $! was saved
  [ -n "$FIFO" ] && rm -f "$FIFO"
  exit 0
}
trap cleanup TERM INT

FIFO="$(mktemp -u).pcm"
mkfifo "$FIFO"

# The writer. Owns the WAV, reads raw PCM, finalises the header on EOF.
"$FFMPEG" -loglevel error -f s16le -ar 16000 -ac 2 -i "$FIFO" -c:a pcm_s16le -y "$OUT" &
FF_PID=$!

# The capture. 2 channels on purpose: a 2-mic device (one lav per person) lands
# each person on their own channel for clean diarisation, and the pipeline gates
# that path on channels_independent(). A mono mic is upmixed.
#
# BACKEND. Default is ffmpeg, which is what has always shipped and which honours
# the avfoundation device INDEX that init.lua picks (including its
# prefer-built-in-over-Bluetooth redirect).
#
# Measured 2026-09-23 on this Mac, MacBook Pro Microphone, 20 second captures:
#
#     ffmpeg -f avfoundation   17.74-17.85s of audio per 20s wall   10.8-11.1% lost
#     sox/rec  (coreaudio)     20.00s        per 20s wall            0.0% lost
#
# The loss is identical with and without resampling, with and without the stereo
# upmix, and with -thread_queue_size 4096 or -capture_raw_data, so it is not the
# resampler or the buffer size. ffmpeg's own progress clock still reports 20s, so
# the samples are dropped rather than slowed: the track ends up ~11% SHORT and
# drifts progressively against them.wav, which is captured by the Core Audio tap
# and is exact. That is the deficit visible in all 8 meetings on disk (10.2-26.7%).
#
# sox is NOT the default yet because it selects the system DEFAULT input rather
# than an avfoundation index, so it would silently ignore the Bluetooth redirect.
# Set UT_MIC_BACKEND=sox to use it. helpers/bin/mic-loss-test.sh measures both.
BACKEND="${UT_MIC_BACKEND:-ffmpeg}"
if [ "$BACKEND" = "sox" ] && command -v rec >/dev/null 2>&1; then
  if [ "$MAXSEC" -gt 0 ] 2>/dev/null; then TRIM=(trim 0 "$MAXSEC"); else TRIM=(); fi
  rec -q -c 2 -r 16000 -b 16 -t raw -e signed-integer - ${TRIM[@]+"${TRIM[@]}"} \
      > "$FIFO" 2>"$MIC_LOG" &
else
  TARGS=()
  [ "$MAXSEC" -gt 0 ] 2>/dev/null && TARGS=(-t "$MAXSEC")
  "$FFMPEG" -loglevel error -f avfoundation -i ":$DEV" -ar 16000 -ac 2 \
            ${TARGS[@]+"${TARGS[@]}"} -f s16le - > "$FIFO" 2>"$MIC_LOG" &
fi
MIC_PID=$!

# ─── guard: stop ourselves if Hammerspoon stops telling us it is alive ────────
# Only enforced when the heartbeat file actually exists, so an older init.lua
# that does not write one keeps the previous behaviour.
if [ "$MAXSEC" -gt 0 ] 2>/dev/null || [ -n "$HB" ]; then
  MAIN=$$
  (
    START=$(date +%s)
    while kill -0 "$MAIN" 2>/dev/null; do
      sleep 15
      NOW=$(date +%s)
      # Belt to the -t brace: if the capture backend ignores its own duration
      # limit we still stop here.
      if [ "$MAXSEC" -gt 0 ] 2>/dev/null && [ $((NOW - START)) -ge $((MAXSEC + 30)) ]; then
        kill -TERM "$MAIN" 2>/dev/null; exit 0
      fi
      if [ -n "$HB" ] && [ -f "$HB" ]; then
        AGE=$(( NOW - $(stat -f %m "$HB" 2>/dev/null || echo "$NOW") ))
        if [ "$AGE" -gt 90 ]; then kill -TERM "$MAIN" 2>/dev/null; exit 0; fi
      fi
    done
  ) &
  GUARD_PID=$!
fi

wait "$MIC_PID"   # normal path: -t elapsed, or the device went away
cleanup
