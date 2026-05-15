-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Free, local-only Whisper push-to-talk dictation for macOS.
-- https://github.com/antoineryan-hash/upscale-talk

local WAV     = "/tmp/upscale-talk.wav"
local MODEL   = os.getenv("HOME") .. "/.upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local recording = false
local recordingTask = nil

local function startRec()
  if recording then return end
  recording = true
  os.remove(WAV)
  recordingTask = hs.task.new(FFMPEG, nil,
    {"-f", "avfoundation", "-i", ":0", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", "-y", WAV})
  recordingTask:start()
  hs.alert.show("🎤", 0.3)
end

local function stopRec()
  if not recording then return end
  recording = false
  if recordingTask then
    recordingTask:terminate()
    recordingTask = nil
  end
  hs.alert.show("⏳", 0.3)

  -- Give ffmpeg a moment to finalise the WAV header
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

-- fn key (Globe) listener via flagsChanged event tap.
-- event:getFlags().fn is true on press, false on release.
local fnTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
  if event:getFlags().fn then
    startRec()
  else
    stopRec()
  end
  return false
end)
fnTap:start()

hs.alert.show("upscale-talk ready — hold fn to dictate", 1.5)
