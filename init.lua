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

-- ─── Recording indicator (pulsing red dot) ───────────────────────────────────
local recIndicator = nil
local recPulseTimer = nil

local function showRecordingIndicator()
  if recIndicator then return end
  recIndicator = hs.canvas.new(indicatorFrame())
  recIndicator:level(hs.canvas.windowLevels.overlay)
  recIndicator:behavior({"canJoinAllSpaces", "stationary"})
  recIndicator[1] = {
    type      = "circle",
    action    = "fill",
    fillColor = {red = 1, green = 0.15, blue = 0.15, alpha = 1.0},
    radius    = INDICATOR_SIZE / 2 - 3,
    center    = {x = INDICATOR_SIZE / 2, y = INDICATOR_SIZE / 2},
  }
  recIndicator:show()

  local t0 = hs.timer.secondsSinceEpoch()
  recPulseTimer = hs.timer.doEvery(0.04, function()
    if not recIndicator then return end
    local elapsed = hs.timer.secondsSinceEpoch() - t0
    -- Sine pulse, alpha 0.35 → 1.0, 1.2-second cycle
    local alpha = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(elapsed * math.pi * 2 / 1.2))
    recIndicator[1].fillColor = {red = 1, green = 0.15, blue = 0.15, alpha = alpha}
  end)
end

local function hideRecordingIndicator()
  if recPulseTimer then recPulseTimer:stop(); recPulseTimer = nil end
  if recIndicator then recIndicator:delete(); recIndicator = nil end
end

-- ─── Transcribing indicator (pulsing pen ✍️ at same anchor) ──────────────────
local transIndicator = nil
local transPulseTimer = nil

local function showTranscribingIndicator()
  if transIndicator then return end
  transIndicator = hs.canvas.new(indicatorFrame())
  transIndicator:level(hs.canvas.windowLevels.overlay)
  transIndicator:behavior({"canJoinAllSpaces", "stationary"})
  transIndicator[1] = {
    type          = "text",
    text          = "✍️",
    textSize      = 18,
    textAlignment = "center",
    frame         = {x = 0, y = 1, w = INDICATOR_SIZE, h = INDICATOR_SIZE},
  }
  transIndicator:show()

  local t0 = hs.timer.secondsSinceEpoch()
  transPulseTimer = hs.timer.doEvery(0.04, function()
    if not transIndicator then return end
    local elapsed = hs.timer.secondsSinceEpoch() - t0
    -- Faster pulse (0.7-second cycle) signals "working hard"; alpha 0.45 → 1.0
    local alpha = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(elapsed * math.pi * 2 / 0.7))
    transIndicator:alpha(alpha)
  end)
end

local function hideTranscribingIndicator()
  if transPulseTimer then transPulseTimer:stop(); transPulseTimer = nil end
  if transIndicator then transIndicator:delete(); transIndicator = nil end
end

-- ─── Async transcribe + paste ────────────────────────────────────────────────
local function transcribeAndPaste(wavPath)
  local task = hs.task.new(WHISPER, function(exitCode, stdOut, _stdErr)
    hideTranscribingIndicator()  -- always hide, even on failure
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
  showTranscribingIndicator()

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
