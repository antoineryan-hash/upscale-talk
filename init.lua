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

local function stopRec()
  if not recording then return end
  recording = false
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  if recordingTask then
    recordingTask:terminate()
    recordingTask = nil
  end
  hs.alert.show("⏳", 0.3)

  -- Give ffmpeg ~0.3s to finalise the WAV header
  hs.timer.doAfter(0.3, function()
    local cmd = string.format("%s -m %q -f %q -nt -np 2>/dev/null", WHISPER, MODEL, WAV)
    local out = hs.execute(cmd)
    local text = (out or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text > 0 then
      local prev = hs.pasteboard.getContents()
      hs.pasteboard.setContents(text)
      hs.osascript.applescript([[tell application "System Events" to keystroke "v" using command down]])
      hs.timer.doAfter(0.5, function()
        if prev then hs.pasteboard.setContents(prev) end
      end)
    end
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
-- We don't rely on this for the UP edge — see releaseWatchdog in startRec().
local fnTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
  if event:getFlags().fn and not recording then
    startRec()
  end
  return false
end)
fnTap:start()

hs.alert.show("upscale-talk ready — hold fn to dictate", 1.5)
