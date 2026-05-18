-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Double-tap fn → toggle "locked" recording (hands-free); tap fn again to stop.
-- Every transcription is saved to ~/upscale-talk/history/ and reachable
-- via the 🎤 menubar icon (click to copy to clipboard).
-- Free, local-only Whisper push-to-talk dictation for macOS.
-- https://github.com/antoineryan-hash/upscale-talk

local HOME    = os.getenv("HOME")
local WAV     = "/tmp/upscale-talk.wav"
local MODEL   = HOME .. "/upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local HISTORY_DIR    = HOME .. "/upscale-talk/history"
local HISTORY_MAX    = 20      -- entries shown in menubar
local DOUBLE_TAP_WINDOW = 0.4

local recording              = false
local toggleMode             = false
local recordingTask          = nil
local releaseWatchdog        = nil
local pendingTranscribeTimer = nil
local lastFnDownTime         = 0

-- Ensure history dir exists at startup
os.execute("mkdir -p " .. HISTORY_DIR)

-- ─── Auto-calibrate ffmpeg startup latency for this machine ──────────────────
-- The animation duration is tuned from this value so the visual "settles"
-- right when ffmpeg actually starts capturing — no fixed magic numbers, no
-- per-Mac tweaking needed.
local MEASURED_STARTUP_SECS = 0.4  -- fallback default, replaced on first calibration

local function calibrateStartup()
  local testWav = "/tmp/upscale-talk-calibrate.wav"
  os.remove(testWav)
  local dev = hs.audiodevice.defaultInputDevice()
  local devName = dev and dev:name() or "MacBook Pro Microphone"
  local startEpoch = hs.timer.secondsSinceEpoch()
  local task = hs.task.new("/opt/homebrew/bin/ffmpeg", function(_, _, _)
    os.remove(testWav)
  end, {
    "-f", "avfoundation", "-i", ":" .. devName,
    "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
    "-flush_packets", "1",
    "-t", "1.5",  -- only need a short test
    "-y", testWav,
  })
  task:start()

  -- Poll for first audio bytes, then record the latency
  local poll
  poll = hs.timer.doEvery(0.02, function()
    local attr = hs.fs.attributes(testWav)
    local size = attr and attr.size or 0
    local elapsed = hs.timer.secondsSinceEpoch() - startEpoch
    if size > 100 then
      MEASURED_STARTUP_SECS = elapsed
      print(string.format("[upscale-talk] calibrated ffmpeg startup: %.3fs", elapsed))
      poll:stop()
      task:terminate()
    elseif elapsed > 3.0 then
      -- Calibration failed (mic in use? permission missing?). Keep fallback.
      print("[upscale-talk] calibration timeout — keeping default 0.4s")
      poll:stop()
      task:terminate()
    end
  end)
end

-- Run calibration after Hammerspoon settles (don't fight startup)
hs.timer.doAfter(2.0, calibrateStartup)

-- Kill any orphan ffmpeg processes left from a previous Hammerspoon session
-- (cold-restart can detach our child ffmpeg, leaving it recording forever)
os.execute("pkill -9 -f 'ffmpeg.*upscale-talk' 2>/dev/null; true")

-- ─── Indicator anchor (top-right of screen, just below menubar) ──────────────
local INDICATOR_SIZE   = 22
local INDICATOR_MARGIN = 24
local INDICATOR_TOP    = 36

local function indicatorFrame()
  local sf = hs.screen.mainScreen():fullFrame()
  return {
    x = sf.x + sf.w - INDICATOR_SIZE - INDICATOR_MARGIN,
    y = sf.y + INDICATOR_TOP,
    w = INDICATOR_SIZE,
    h = INDICATOR_SIZE,
  }
end

local RED   = {red = 1.00, green = 0.15, blue = 0.15}
local GREEN = {red = 0.20, green = 0.85, blue = 0.30}

local function pulseAlpha(t0, period, lo, hi)
  local elapsed = hs.timer.secondsSinceEpoch() - t0
  return lo + (hi - lo) * (0.5 + 0.5 * math.sin(elapsed * math.pi * 2 / period))
end

-- ─── Recording indicator (pulsing red dot; thin white ring when locked) ──────
local recIndicator  = nil
local recPulseTimer = nil

local function showRecordingIndicator(locked)
  if recIndicator then recIndicator:delete() end
  if recPulseTimer then recPulseTimer:stop(); recPulseTimer = nil end

  recIndicator = hs.canvas.new(indicatorFrame())
  recIndicator:level(hs.canvas.windowLevels.overlay)
  recIndicator:behavior({"canJoinAllSpaces", "stationary"})

  local center = {x = INDICATOR_SIZE / 2, y = INDICATOR_SIZE / 2}
  local redR   = INDICATOR_SIZE / 2 - 3

  recIndicator[1] = {
    type      = "circle",
    action    = "fill",
    fillColor = {red = RED.red, green = RED.green, blue = RED.blue, alpha = 1.0},
    radius    = redR,
    center    = center,
  }
  if locked then
    recIndicator[2] = {
      type        = "circle",
      action      = "stroke",
      strokeColor = {white = 1.0, alpha = 0.9},
      strokeWidth = 1.5,
      radius      = INDICATOR_SIZE / 2 - 1,
      center      = center,
    }
  end
  recIndicator:show()

  local t0 = hs.timer.secondsSinceEpoch()
  recPulseTimer = hs.timer.doEvery(0.04, function()
    if not recIndicator then return end
    local a = pulseAlpha(t0, 1.2, 0.35, 1.0)
    recIndicator[1].fillColor = {red = RED.red, green = RED.green, blue = RED.blue, alpha = a}
  end)
end

local function hideRecordingIndicator()
  if recPulseTimer then recPulseTimer:stop(); recPulseTimer = nil end
  if recIndicator then recIndicator:delete(); recIndicator = nil end
end

-- ─── Transcribing indicator (pulsing green dot) ──────────────────────────────
local transIndicator  = nil
local transPulseTimer = nil

local function showTranscribingIndicator()
  if transIndicator then return end
  transIndicator = hs.canvas.new(indicatorFrame())
  transIndicator:level(hs.canvas.windowLevels.overlay)
  transIndicator:behavior({"canJoinAllSpaces", "stationary"})
  transIndicator[1] = {
    type      = "circle",
    action    = "fill",
    fillColor = {red = GREEN.red, green = GREEN.green, blue = GREEN.blue, alpha = 1.0},
    radius    = INDICATOR_SIZE / 2 - 3,
    center    = {x = INDICATOR_SIZE / 2, y = INDICATOR_SIZE / 2},
  }
  transIndicator:show()

  local t0 = hs.timer.secondsSinceEpoch()
  transPulseTimer = hs.timer.doEvery(0.04, function()
    if not transIndicator then return end
    local a = pulseAlpha(t0, 0.7, 0.45, 1.0)
    transIndicator[1].fillColor = {red = GREEN.red, green = GREEN.green, blue = GREEN.blue, alpha = a}
  end)
end

local function hideTranscribingIndicator()
  if transPulseTimer then transPulseTimer:stop(); transPulseTimer = nil end
  if transIndicator then transIndicator:delete(); transIndicator = nil end
end

-- ─── Warmup indicator: solid red dot in damped circular orbit ────────────────
-- "Guitar string settling to rest" — shown the instant fn is pressed, while
-- ffmpeg is opening the audio device. The dot spins in a small orbit whose
-- radius exponentially decays. When the WAV file actually has bytes (ffmpeg
-- captured first sample = mic is live), the orbit ends and the regular
-- pulsing red recording indicator takes over.
local warmupIndicator  = nil
local warmupPulseTimer = nil
local warmupPoll       = nil

local function showWarmupIndicator()
  if warmupIndicator then warmupIndicator:delete() end
  if warmupPulseTimer then warmupPulseTimer:stop(); warmupPulseTimer = nil end

  warmupIndicator = hs.canvas.new(indicatorFrame())
  warmupIndicator:level(hs.canvas.windowLevels.overlay)
  warmupIndicator:behavior({"canJoinAllSpaces", "stationary"})

  local centerX = INDICATOR_SIZE / 2
  local centerY = INDICATOR_SIZE / 2
  local dotR    = INDICATOR_SIZE / 2 - 5  -- slightly smaller so orbit fits in frame

  warmupIndicator[1] = {
    type      = "circle",
    action    = "fill",
    fillColor = {red = RED.red, green = RED.green, blue = RED.blue, alpha = 1.0},
    radius    = dotR,
    center    = {x = centerX, y = centerY},
  }
  warmupIndicator:show()

  -- Damped circular orbit: amp = INITIAL * exp(-t / TAU)
  -- DAMP_TAU is auto-tuned from the measured ffmpeg startup latency so the
  -- visual is ~95% settled exactly when ffmpeg crosses the readiness threshold.
  -- (exp(-3) ≈ 0.05, so tau = MEASURED / 3.)
  local t0 = hs.timer.secondsSinceEpoch()
  local INITIAL_AMP = 3.5
  local FREQ        = 12.0
  local DAMP_TAU    = MEASURED_STARTUP_SECS / 3.0

  warmupPulseTimer = hs.timer.doEvery(0.02, function()
    if not warmupIndicator then return end
    local elapsed = hs.timer.secondsSinceEpoch() - t0
    local amp     = INITIAL_AMP * math.exp(-elapsed / DAMP_TAU)
    local angle   = elapsed * FREQ * 2 * math.pi
    warmupIndicator[1].center = {
      x = centerX + amp * math.cos(angle),
      y = centerY + amp * math.sin(angle),
    }
  end)
end

local function hideWarmupIndicator()
  if warmupPulseTimer then warmupPulseTimer:stop(); warmupPulseTimer = nil end
  if warmupIndicator then warmupIndicator:delete(); warmupIndicator = nil end
  if warmupPoll then warmupPoll:stop(); warmupPoll = nil end
end

-- ─── Transcription history (menubar) ─────────────────────────────────────────
local menubar = nil
local recentTranscriptions = {}  -- [{time = "HH:MM:SS", text = "..."}]

local function refreshMenubar()
  if not menubar then return end
  local menu = {}
  if #recentTranscriptions == 0 then
    table.insert(menu, {title = "No transcriptions yet — hold fn to dictate", disabled = true})
  else
    table.insert(menu, {title = "Recent transcriptions (click to copy)", disabled = true})
    table.insert(menu, {title = "-"})
    for _, item in ipairs(recentTranscriptions) do
      local preview = item.text:gsub("\n", " "):sub(1, 70)
      if #item.text > 70 then preview = preview .. "…" end
      table.insert(menu, {
        title = "[" .. item.time .. "]  " .. preview,
        fn = function()
          hs.pasteboard.setContents(item.text)
          hs.alert.show("📋 Copied to clipboard", 0.7)
        end,
      })
    end
  end
  table.insert(menu, {title = "-"})
  table.insert(menu, {
    title = "Open History Folder…",
    fn = function() hs.execute("open " .. HISTORY_DIR) end,
  })
  menubar:setMenu(menu)
end

-- Load existing history files into the in-memory cache at startup
local function loadHistoryFromDisk()
  local handle = io.popen("ls -t " .. HISTORY_DIR .. "/*.txt 2>/dev/null | head -" .. HISTORY_MAX)
  if not handle then return end
  for path in handle:lines() do
    local f = io.open(path, "r")
    if f then
      local text = f:read("*a") or ""
      f:close()
      -- Filename format: YYYY-MM-DD_HH-MM-SS.txt → extract HH:MM:SS
      local timePart = path:match("(%d%d%-%d%d%-%d%d)%.txt$") or "??-??-??"
      timePart = timePart:gsub("-", ":")
      table.insert(recentTranscriptions, {time = timePart, text = text})
    end
  end
  handle:close()
end

local function saveToHistory(text)
  -- Write timestamped file
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local path = HISTORY_DIR .. "/" .. stamp .. ".txt"
  local f = io.open(path, "w")
  if f then f:write(text); f:close() end
  -- Update in-memory cache (newest first)
  table.insert(recentTranscriptions, 1, {time = os.date("%H:%M:%S"), text = text})
  while #recentTranscriptions > HISTORY_MAX do
    table.remove(recentTranscriptions)
  end
  refreshMenubar()
end

-- ─── Async transcribe + paste ────────────────────────────────────────────────
local function transcribeAndPaste(wavPath)
  local task = hs.task.new(WHISPER, function(exitCode, stdOut, _stdErr)
    hideTranscribingIndicator()
    if exitCode ~= 0 then return end
    local text = (stdOut or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 then return end

    -- Save to history FIRST — so even if the paste lands in the wrong window,
    -- the transcription is recoverable from the menubar / history folder.
    saveToHistory(text)

    -- Then attempt to paste at the current cursor
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    hs.osascript.applescript([[tell application "System Events" to keystroke "v" using command down]])
    hs.timer.doAfter(0.5, function()
      if prev then hs.pasteboard.setContents(prev) end
    end)
  end, {"-m", MODEL, "-f", wavPath, "-nt", "-np"})
  task:start()
end

local function cancelPendingTranscribe()
  if pendingTranscribeTimer then
    pendingTranscribeTimer:stop()
    pendingTranscribeTimer = nil
  end
  hideTranscribingIndicator()
  os.remove(WAV)
end

-- ─── Recording lifecycle ─────────────────────────────────────────────────────
local function stopRec()
  if not recording then return end
  recording = false
  toggleMode = false
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  if recordingTask then
    recordingTask:terminate()
    recordingTask = nil
  end
  -- Belt-and-suspenders: if terminate() didn't actually kill ffmpeg (happens
  -- if the task was orphaned by a Hammerspoon restart), force-kill it via
  -- shell. Without this, ffmpeg keeps recording silence into the WAV forever.
  os.execute("pkill -9 -f 'ffmpeg.*upscale-talk' 2>/dev/null; true")
  hideWarmupIndicator()
  hideRecordingIndicator()
  showTranscribingIndicator()

  local snapshotPath = "/tmp/upscale-talk-" .. os.time() .. "-" .. math.random(1000, 9999) .. ".wav"
  pendingTranscribeTimer = hs.timer.doAfter(0.3, function()
    pendingTranscribeTimer = nil
    os.execute(string.format("mv %q %q 2>/dev/null", WAV, snapshotPath))
    transcribeAndPaste(snapshotPath)
    -- Keep WAVs around for 5 minutes (was 10s) — enough buffer to re-transcribe
    -- if something goes wrong, but bounded so /tmp doesn't fill up
    hs.timer.doAfter(300, function() os.remove(snapshotPath) end)
  end)
end

local function startRec(asToggle)
  if recording then return end
  recording = true
  toggleMode = asToggle and true or false
  os.remove(WAV)

  -- Show "DON'T speak yet" indicator INSTANTLY (before ffmpeg even spawns)
  showWarmupIndicator()

  local dev = hs.audiodevice.defaultInputDevice()
  local devName = dev and dev:name() or "MacBook Pro Microphone"

  recordingTask = hs.task.new(FFMPEG, nil,
    {"-f", "avfoundation", "-i", ":" .. devName,
     "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
     -- -flush_packets 1: write each audio packet to disk immediately so the
     -- warmup-poll sees the file grow as soon as the mic is live, instead of
     -- waiting for ffmpeg's default 1+s output buffer to flush.
     "-flush_packets", "1",
     "-y", WAV})
  recordingTask:start()

  -- Poll the WAV file size. The moment ffmpeg has written any real audio data
  -- (file size > WAV-header-only), switch from warmup to red recording dot.
  -- Timeout fallback is 2× the calibrated startup time (safety margin).
  local pollStart = hs.timer.secondsSinceEpoch()
  local timeoutSecs = math.max(MEASURED_STARTUP_SECS * 2.5, 0.8)
  warmupPoll = hs.timer.doEvery(0.03, function()
    local attr = hs.fs.attributes(WAV)
    local size = attr and attr.size or 0
    local elapsed = hs.timer.secondsSinceEpoch() - pollStart
    if size > 100 or elapsed > timeoutSecs then
      if warmupPoll then warmupPoll:stop(); warmupPoll = nil end
      hideWarmupIndicator()
      showRecordingIndicator(toggleMode)
    end
  end)

  if not toggleMode then
    releaseWatchdog = hs.timer.doEvery(0.03, function()
      if toggleMode then return end
      local mods = hs.eventtap.checkKeyboardModifiers()
      if not mods.fn then
        stopRec()
      end
    end)
  end
end

local function promoteToToggle()
  toggleMode = true
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  -- If we're still in warmup when the double-tap arrives, the warmupPoll
  -- will switch to red on its own. Otherwise we're already showing red and
  -- need to re-render with the locked-mode ring.
  if not warmupIndicator then
    showRecordingIndicator(true)
  end
end

-- ─── fn-key event tap ────────────────────────────────────────────────────────
local fnTap
fnTap = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.tapDisabledByTimeout,
  hs.eventtap.event.types.tapDisabledByUserInput,
}, function(event)
  local etype = event:getType()
  if etype == hs.eventtap.event.types.tapDisabledByTimeout
     or etype == hs.eventtap.event.types.tapDisabledByUserInput then
    fnTap:start()
    return false
  end

  if not event:getFlags().fn then return false end

  local now = hs.timer.secondsSinceEpoch()
  local sinceLast = now - lastFnDownTime
  lastFnDownTime = now

  if toggleMode then
    stopRec()
    return false
  end

  if sinceLast < DOUBLE_TAP_WINDOW then
    cancelPendingTranscribe()
    if recording then
      promoteToToggle()
    else
      startRec(true)
    end
    return false
  end

  if not recording then
    startRec(false)
  end
  return false
end)
fnTap:start()

-- ─── Menubar setup (must come AFTER refreshMenubar definition) ───────────────
menubar = hs.menubar.new()
if menubar then
  menubar:setTitle("🎤")
  menubar:setTooltip("upscale-talk — recent transcriptions")
  loadHistoryFromDisk()
  refreshMenubar()
end

hs.alert.show("upscale-talk ready — hold fn to dictate, double-tap fn to lock on", 2.0)
