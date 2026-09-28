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
#   phantom         a paste made while fn was held started AND stopped a
#                   meeting 90 ms apart (28 Sep)
#   quick-stop      that 90 ms meeting then froze Hammerspoon until it was
#                   force quit: a capture child held hs.task's pipes (28 Sep)
#
# --quick runs only the phantom and quick-stop checks (no 10 s meeting, no
# transcript pipeline). --cap adds the cap test.
#
# Needs meeting mode installed and Hammerspoon running the v0.6.3 config.
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

QUICK=0; CAP=0
for a in "$@"; do
  case "$a" in --quick) QUICK=1 ;; --cap) CAP=1 ;; esac
done

finish() {
  if [ -n "${QDIR:-}" ] && hs_run "utDebug.status()" | grep -q "meeting_active=true"; then
    hs_run "utDebug.stop()" >/dev/null; note "stopped the test meeting that was still recording"
  fi
  echo
  echo "  $PASS passed, $FAIL failed"
  [ -n "${QDIR:-}" ] && echo "  quick-stop test meeting left at $QDIR - delete it when you are done"
  [ -n "${DIR:-}" ] && echo "  test meeting left at $DIR - delete it when you are done"
  exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
}

echo "upscale-talk meeting self-test  (config $(hs_run "utDebug.version" | tr -d '\r'))"
echo

# utDebug.feed drives the LIVE fn tap. If a dictation is running, or fn is held,
# a fed tap lands in the middle of it and can abandon someone's take (it did,
# while this test was being written). So refuse rather than interfere.
busy() {
  hs_run "utDebug.status()" | grep -q "recording=true\|meeting_active=true\|fn_down=true" && return 0
  hs_run "hs.eventtap.checkKeyboardModifiers().fn" | grep -q true
}
if busy; then
  echo "  upscale-talk is in use (dictating, recording, or fn held)."
  echo "  Run this again when you are not using it."
  exit 2
fi

# ─── 0a. phantom taps: only a real fn down-edge counts ───────────────────────
# Hands the fn tap the flagsChanged events our own paste makes (Cmd, with fn
# set) straight through utDebug.feed: nothing is posted to macOS, nothing typed.
if ! hs_run "utDebug.feed ~= nil" | grep -q true; then
  bad "utDebug.feed missing - reload Hammerspoon on v0.6.3 or later"
else
  hs_run "utDebug.feed(55, {fn=true, cmd=true})" >/dev/null; sleep 0.1
  hs_run "utDebug.feed(55, {fn=true})" >/dev/null; sleep 0.3
  ST="$(hs_run "utDebug.status()")"
  if echo "$ST" | grep -q "meeting_active=false" && echo "$ST" | grep -q "recording=false"; then
    ok "a paste's Cmd events (with fn set) start nothing"
  else
    bad "Cmd events with fn set started something: $ST"
    hs_run "utDebug.stop()" >/dev/null
  fi

  # ─── 0b. quick stop: a real double-tap, a bounced tap, a stop at 1.5 s ─────
  # The whole sequence runs on Hammerspoon's own timers in ONE call: hs -c round
  # trips cannot stretch it past the 2 s short-meeting line, and the first tap's
  # dictation is abandoned inside the double-tap before it can be transcribed or
  # pasted anywhere.
  if ! hs_run "utDebug.status()" | grep -q "meeting_available=true"; then
    note "meeting mode is not installed here - quick-stop checks skipped"
  else
  if busy; then echo "  upscale-talk came into use mid-test - stopping here"; finish; fi
  QDIR="$(hs_run "utDebug.feed(63,{fn=true}); utDebug.feed(63,{}); utDebug.feed(63,{fn=true}); utDebug.feed(63,{}); \
    UT_SELFTEST = {dir = utDebug.status():match('dir=(%S+)')}; \
    UT_SELFTEST.t1 = hs.timer.doAfter(0.5, function() utDebug.feed(63,{fn=true}); utDebug.feed(63,{}); \
      UT_SELFTEST.grace = utDebug.meetingActive() end); \
    UT_SELFTEST.t2 = hs.timer.doAfter(1.5, function() utDebug.feed(63,{fn=true}); utDebug.feed(63,{}); \
      UT_SELFTEST.stopped = not utDebug.meetingActive() end); \
    return UT_SELFTEST.dir" | tail -1 | tr -d '\r')"
  if [ -n "$QDIR" ] && [ "$QDIR" != "nil" ] && [ -d "$QDIR" ]; then
    ok "a real fn double-tap still starts a meeting"
  else
    bad "a real fn double-tap did not start a meeting"; QDIR=""
  fi
  sleep 4.5
  # The 28 Sep freeze: ask Hammerspoon something, with a deadline.
  if python3 -c "import subprocess; subprocess.run(['$HS','-c','1+1'], stdin=subprocess.DEVNULL, capture_output=True, timeout=2)" 2>/dev/null; then
    ok "Hammerspoon answers 3 s after a quick stop"
  else
    bad "Hammerspoon did NOT answer 3 s after a quick stop - the 28 Sep freeze"
  fi
  hs_run "UT_SELFTEST.grace" | grep -q true \
    && ok "a tap 0.5 s in is ignored (stop grace)" || bad "a tap 0.5 s in ended the meeting"
  hs_run "UT_SELFTEST.stopped" | grep -q true \
    && ok "a tap 1.5 s in stopped it" || bad "a tap 1.5 s in did not stop the meeting"
  if [ -n "$QDIR" ] && [ -f "$QDIR/too-short.txt" ] && [ ! -d "$QDIR/me_diar" ]; then
    ok "under 2 s: noted in too-short.txt, transcript step skipped"
  else
    bad "the short meeting was not skipped (${QDIR:-no folder})"
  fi
  if [ -n "$QDIR" ] && pgrep -f "capture-(mic|system).sh $QDIR" >/dev/null; then
    bad "capture wrappers still running for $QDIR"
  else
    ok "no capture processes left behind"
  fi
  if ls "${TMPDIR:-/tmp}"/*.pcm >/dev/null 2>&1; then
    bad "leftover fifo(s): $(ls "${TMPDIR:-/tmp}"/*.pcm | tr '\n' ' ')"
  else
    ok "no fifos left behind"
  fi
  fi
fi
[ "$QUICK" = 1 ] && finish
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
if [ "$CAP" = 1 ]; then
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

finish
