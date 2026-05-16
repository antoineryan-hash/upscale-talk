-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Free, local-only Whisper push-to-talk dictation for macOS.
-- https://github.com/antoineryan-hash/upscale-talk

local WAV     = "/tmp/upscale-talk.wav"
local MODEL   = os.getenv("HOME") .. "/.upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local recording = false
local recordingTask = nil
local releaseWatchdog = nil

-- ─── Recording indicator (pulsing red dot, top-right of screen) ──────────────
local indicator = nil
local pulseTimer = nil

local function showRecordingIndicator()
  if indicator then return end
  local sf = hs.screen.mainScreen():fullFrame()
  local SIZE   = 18
  local MARGIN = 26
  local x = sf.x + sf.w - SIZE - MARGIN
  local y = sf.y + 38  -- just below menubar
  indicator = hs.canvas.new({x = x, y = y, w = SIZE, h = SIZE})
  indicator:level(hs.canvas.windowLevels.overlay)
  indicator:behavior({"canJoinAllSpaces", "stationary"})
  indicator[1] = {
    type        = "circle",
    action      = "fill",
    fillColor   = {red = 1, green = 0.15, blue = 0.15, alpha = 1.0},
    radius      = SIZE / 2 - 2,
    center      = {x = SIZE / 2, y = SIZE / 2},
  }
  indicator:show()

  -- Pulse alpha between 0.35 and 1.0 over a ~1.2-second cycle (sine wave)
  local t0 = hs.timer.secondsSinceEpoch()
  pulseTimer = hs.timer.doEvery(0.04, function()
    if not indicator then return end
    local elapsed = hs.timer.secondsSinceEpoch() - t0
    local alpha = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(elapsed * math.pi * 2 / 1.2))
    indicator[1].fillColor = {red = 1, green = 0.15, blue = 0.15, alpha = alpha}
  end)
end

local function hideRecordingIndicator()
  if pulseTimer then pulseTimer:stop(); pulseTimer = nil end
  if indicator then indicator:delete(); indicator = nil end
end

-- ─── Async transcribe + paste ────────────────────────────────────────────────
local function transcribeAndPaste(wavPath)
  local task = hs.task.new(WHISPER, function(exitCode, stdOut, _stdErr)
    if exitCode ~= 0 then return end
    local text = (stdOut or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 then return end
    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    hs.osascript.applescript([[tell application "System Events" to keystroke "v" using command down]])
    hs.timer.doAfter(0.5, function()
      if prev then hs.pasteboard.setContents(prev) end
    end)
  end, {"-m", MODEL, "-f", wavPath, "-nt", "-np"})
  task:start()
end

-- ─── Recording lifecycle ─────────────────────────────────────────────────────
local function stopRec()
  if not recording then return end
  recording = false
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  if recordingTask then
    recordingTask:terminate()
    recordingTask = nil
  end
  hideRecordingIndicator()
  hs.alert.show("⏳", 0.3)

  -- Snapshot the WAV so a fast new recording doesn't overwrite mid-transcribe
  local snapshotPath = "/tmp/upscale-talk-" .. os.time() .. "-" .. math.random(1000, 9999) .. ".wav"
  hs.timer.doAfter(0.3, function()
    os.execute(string.format("mv %q %q 2>/dev/null", WAV, snapshotPath))
    transcribeAndPaste(snapshotPath)
    hs.timer.doAfter(10, function() os.remove(snapshotPath) end)
  end)
end

local function startRec()
  if recording then return end
  recording = true
  os.remove(WAV)

  -- Query the system's current default input device by NAME (avoids virtual
  -- loopback devices like LoomAudioDevice that may sit at lower indices).
  local dev = hs.audiodevice.defaultInputDevice()
  local devName = dev and dev:name() or "MacBook Pro Microphone"

  recordingTask = hs.task.new(FFMPEG, nil,
    {"-f", "avfoundation", "-i", ":" .. devName,
     "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", "-y", WAV})
  recordingTask:start()

  showRecordingIndicator()

  -- macOS 26+ sometimes swallows the fn-UP flagsChanged event before our
  -- tap sees it. Poll every 30 ms for fn-state to detect release reliably.
  releaseWatchdog = hs.timer.doEvery(0.03, function()
    local mods = hs.eventtap.checkKeyboardModifiers()
    if not mods.fn then
      stopRec()
    end
  end)
end

-- ─── fn-key event tap (DOWN edge only; release handled by watchdog) ─────────
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
  if event:getFlags().fn and not recording then
    startRec()
  end
  return false
end)
fnTap:start()

hs.alert.show("upscale-talk ready — hold fn to dictate", 1.5)
