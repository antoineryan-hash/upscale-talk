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

-- Async transcribe + paste. Runs on a background queue so the main thread
-- stays responsive to new fn-presses while a prior transcription is in flight.
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

local function stopRec()
  if not recording then return end
  recording = false
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  if recordingTask then
    recordingTask:terminate()
    recordingTask = nil
  end
  hs.alert.show("⏳", 0.3)

  -- Snapshot the WAV path NOW so a fast new recording doesn't overwrite the
  -- file we're about to transcribe before whisper-cli reads it.
  local snapshotPath = "/tmp/upscale-talk-" .. os.time() .. "-" .. math.random(1000, 9999) .. ".wav"
  hs.timer.doAfter(0.3, function()
    -- Move (not copy) so we don't waste disk on duplicates
    os.execute(string.format("mv %q %q 2>/dev/null", WAV, snapshotPath))
    transcribeAndPaste(snapshotPath)
    -- Clean up the snapshot ~10s later
    hs.timer.doAfter(10, function() os.remove(snapshotPath) end)
  end)
end

local function startRec()
  if recording then return end
  recording = true
  os.remove(WAV)

  -- Query the system's current default input device by NAME so we don't
  -- accidentally record from a virtual loopback (e.g. Loom, BlackHole) that
  -- happens to have a lower device index than the real mic.
  local dev = hs.audiodevice.defaultInputDevice()
  local devName = dev and dev:name() or "MacBook Pro Microphone"

  recordingTask = hs.task.new(FFMPEG, nil,
    {"-f", "avfoundation", "-i", ":" .. devName,
     "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", "-y", WAV})
  recordingTask:start()
  hs.alert.show("🎤", 0.3)

  -- On macOS 26+, the fn-UP flagsChanged event is sometimes swallowed by
  -- the system before reaching our event tap. Poll every 30ms while we're
  -- recording to catch the release reliably.
  releaseWatchdog = hs.timer.doEvery(0.03, function()
    local mods = hs.eventtap.checkKeyboardModifiers()
    if not mods.fn then
      stopRec()
    end
  end)
end

-- fn key (Globe) listener for the DOWN edge via flagsChanged event tap.
-- Also handle tap-disabled events so a transient timeout doesn't permanently
-- kill the binding.
local fnTap
fnTap = hs.eventtap.new({
  hs.eventtap.event.types.flagsChanged,
  hs.eventtap.event.types.tapDisabledByTimeout,
  hs.eventtap.event.types.tapDisabledByUserInput,
}, function(event)
  local etype = event:getType()
  if etype == hs.eventtap.event.types.tapDisabledByTimeout
     or etype == hs.eventtap.event.types.tapDisabledByUserInput then
    fnTap:start()  -- re-enable on transient kill
    return false
  end
  if event:getFlags().fn and not recording then
    startRec()
  end
  return false
end)
fnTap:start()

hs.alert.show("upscale-talk ready — hold fn to dictate", 1.5)
