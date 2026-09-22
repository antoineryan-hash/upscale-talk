#!/bin/bash
# selftest-meeting.sh [--cap] — prove the meeting stop path without a meeting.
#
# Every assertion here exists because something silently went wrong in the field:
#
#   stop            the mic kept recording 12m40s past the stop (Marc, 27 Aug)
#   them-header     a kill at stop time can race the wrapper that finalises
#                   them.wav, which is the file the whole transcript hangs on
#   me-header       every me.wav written before v0.6.2 carried a placeholder
#                   size, which two scripts had to work around
#   cross-kill      stopping a dictation used to SIGKILL a meeting that was
#                   still transcribing, for the 18-29 minutes that takes
#   cap             a capture must stop itself when Hammerspoon dies, because
#                   nothing in Lua can (36 minute run-on, Marc, 3 Sep)
#
# Needs meeting mode installed and Hammerspoon running the v0.6.2 config.
set -uo pipefail
DEST="$HOME/upscale-talk"
MEET="$DEST/meetings"
HS="/opt/homebrew/bin/hs"
[ -x "$HS" ] || HS="$(command -v hs)"
# ALWAYS give hs a closed stdin. With stdin left open and not a terminal, the hs
# CLI waits on it forever - the script then hangs before printing anything,
# which looks exactly like a broken tool. Cost me six minutes to find.
hs_run() { "$HS" -c "$1" < /dev/null 2>/dev/null; }
PASS=0; FAIL=0
ok()   { printf "  PASS  %s\n" "$1"; PASS=$((PASS+1)); }
bad()  { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL+1)); }
note() { printf "        %s\n" "$1"; }

wavsecs() { python3 -c "
import os,sys,wave
p=sys.argv[1]
try:
    w=wave.open(p); hdr=w.getnframes()/float(w.getframerate())
    byt=(os.path.getsize(p)-78)/float(w.getframerate()*w.getnchannels()*2)
    print('%.3f %.3f'%(hdr,byt))
except Exception: print('-1 -1')" "$1"; }

if [ -z "${HS:-}" ] || [ ! -x "$HS" ]; then
  echo "hs command-line tool not found. In Hammerspoon: Preferences > install 'hs'."; exit 2
fi
if ! hs_run "utDebug.version" >/dev/null; then
  echo "utDebug is not exposed. Reload Hammerspoon on v0.6.2 or later."; exit 2
fi

echo "upscale-talk meeting self-test  (config $(hs_run "utDebug.version" | tr -d '\r'))"
echo

# ─── 1. start ────────────────────────────────────────────────────────────────
BEFORE="$(ls -1 "$MEET" 2>/dev/null | wc -l | tr -d ' ')"
hs_run "utDebug.start()" >/dev/null
sleep 10
DIR="$(ls -1dt "$MEET"/*/ 2>/dev/null | head -1)"; DIR="${DIR%/}"
AFTER="$(ls -1 "$MEET" 2>/dev/null | wc -l | tr -d ' ')"
[ "$AFTER" -gt "$BEFORE" ] && ok "meeting started: $(basename "$DIR")" \
                           || bad "no new meeting directory appeared"

MICPID="$(pgrep -f "capture-mic.sh $DIR" | head -1)"
TAPPID="$(pgrep -f "capture-system.sh $DIR" | head -1)"
[ -n "$MICPID" ] && ok "mic capture running (pid $MICPID)" \
                 || bad "mic capture not running - meeting mode or mic permission is broken"
[ -n "$TAPPID" ] && ok "system-audio capture running (pid $TAPPID)" \
                 || bad "tap not running - check Hammerspoon's audio recording permission"

# ─── 2. stop, and time it ────────────────────────────────────────────────────
hs_run "utDebug.stop()" >/dev/null
T0=$(python3 -c "import time;print(time.time())")
GONE=""
for _ in $(seq 1 40); do
  if ! kill -0 "$MICPID" 2>/dev/null && ! kill -0 "$TAPPID" 2>/dev/null; then
    GONE=$(python3 -c "import time;print('%.2f'%(time.time()-$T0))"); break
  fi
  sleep 0.25
done
if [ -n "$GONE" ]; then
  ok "both captures stopped in ${GONE}s"
else
  bad "captures STILL RUNNING 10s after the stop - this is the reported bug"
  note "mic pid $MICPID, tap pid $TAPPID"
fi
sleep 4   # let the wrappers finalise and the pipeline start

# ─── 3. headers ──────────────────────────────────────────────────────────────
for f in me them; do
  read -r HDR BYT <<< "$(wavsecs "$DIR/$f.wav")"
  if [ "$HDR" = "-1" ]; then bad "$f.wav unreadable"; continue; fi
  if python3 -c "import sys;sys.exit(0 if abs($HDR-$BYT)<0.05 else 1)"; then
    ok "$f.wav header finalised (${HDR}s, matches its own bytes)"
  else
    bad "$f.wav header says ${HDR}s but holds ${BYT}s of audio"
    note "a killed writer never patched the RIFF size back in"
  fi
done

# ─── 4. cross-kill: the kill patterns must not match anything else ───────────
# Deterministic rather than timing-based: start a long ffmpeg inside a meetings
# folder, exactly like the post-meeting pipeline's own to_mono and volumedetect
# calls, and assert none of the patterns this config still uses would match it.
# The old pattern, 'ffmpeg.*upscale-talk', matched all of them - so stopping a
# dictation while a meeting was transcribing killed the transcription, for the
# 18 to 29 minutes that takes.
PROBEWAV="$DIR/crosskill-probe.wav"
/opt/homebrew/bin/ffmpeg -loglevel error -re -f lavfi -i "sine=f=440:d=30" \
    -ar 16000 -ac 1 -y "$PROBEWAV" >/dev/null 2>&1 &
PROBE=$!
sleep 1
if kill -0 "$PROBE" 2>/dev/null; then
  HITS=0
  for pat in 'ffmpeg.*/tmp/upscale-talk.wav' 'ffmpeg.*upscale-talk/meetings/.*/me.wav'; do
    if pgrep -f "$pat" 2>/dev/null | grep -qx "$PROBE"; then
      bad "pattern '$pat' matches an unrelated pipeline ffmpeg"
      HITS=$((HITS+1))
    fi
  done
  # And prove the old pattern DID match it, so this test is meaningful.
  if pgrep -f 'ffmpeg.*upscale-talk' 2>/dev/null | grep -qx "$PROBE"; then
    OLDHIT="yes"
  else
    OLDHIT="no"
  fi
  [ "$HITS" -eq 0 ] && ok "no kill pattern matches unrelated ffmpeg work in a meetings folder"
  [ "$OLDHIT" = "yes" ] && note "(the pre-0.6.2 pattern did match it - that was the bug)"
  { kill -9 "$PROBE"; wait "$PROBE"; } 2>/dev/null   # braces: no job-control noise
else
  note "cross-kill probe did not start; skipped"
fi
rm -f "$PROBEWAV"

# ─── 5. the cap, without waiting 3 hours ─────────────────────────────────────
if [ "${1:-}" = "--cap" ]; then
  echo
  echo "  cap test: 20s capture, heartbeat abandoned after 5s"
  HB="$(mktemp)"; OUT="$(mktemp -d)/cap.wav"
  touch "$HB"
  bash "$DEST/bin/capture-mic.sh" "$OUT" 1 600 "$HB" >/dev/null 2>&1 &
  CAPPID=$!
  S=$(python3 -c "import time;print(time.time())")
  # Poll rather than wait: a wedged wrapper must fail this test, not hang it.
  for _ in $(seq 1 160); do
    kill -0 "$CAPPID" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$CAPPID" 2>/dev/null
  E=$(python3 -c "import time;print('%.0f'%(time.time()-$S))")
  if [ "$E" -lt 130 ]; then
    ok "capture stopped itself after ${E}s with a stale heartbeat (cap was 600s)"
  else
    bad "capture ran ${E}s - the heartbeat guard did not fire"
  fi
  read -r HDR BYT <<< "$(wavsecs "$OUT")"
  python3 -c "import sys;sys.exit(0 if abs($HDR-$BYT)<0.05 else 1)" \
    && ok "self-stopped capture still wrote a valid WAV header" \
    || bad "self-stopped capture left a broken header"
  rm -f "$HB" "$OUT"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ -n "${DIR:-}" ] && echo "  test meeting left at $DIR - delete it when you are done"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
