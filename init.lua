-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Double-tap fn → toggle "locked" recording (hands-free); tap fn again to stop.
-- Every transcription is saved to ~/upscale-talk/history/ and reachable
-- via the 🎤 menubar icon (click to copy to clipboard).
-- Free, local-only Whisper push-to-talk dictation for macOS.
-- https://github.com/antoineryan-hash/upscale-talk

local HOME    = os.getenv("HOME")
local MODEL   = HOME .. "/upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local BUFFER_WAV  = "/tmp/upscale-talk-buffer.wav"
local PRE_ROLL_SECS = 0.5  -- include audio from 0.5s BEFORE fn-press
local BG_CYCLE_SECS = 3600 -- restart background ffmpeg every 60 min (bounds buffer to ~115 MB)

local HISTORY_DIR    = HOME .. "/upscale-talk/history"
local HISTORY_MAX    = 20
local DOUBLE_TAP_WINDOW = 0.4

local recording              = false
local toggleMode             = false
local releaseWatchdog        = nil
local pendingExtractTimer    = nil
local lastFnDownTime         = 0
local fnPressEpoch           = 0

-- Background recorder state
local bgRecorder    = nil
local bgStartEpoch  = 0     -- epoch when the current bg ffmpeg started writing
local bgShuttingDown = false

-- Ensure dirs exist at startup
os.execute("mkdir -p " .. HISTORY_DIR)

-- Kill any orphan ffmpeg processes left from a previous Hammerspoon session
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

-- ─── Transcription history (menubar) ─────────────────────────────────────────
local menubar = nil
local recentTranscriptions = {}

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

local function loadHistoryFromDisk()
  local handle = io.popen("ls -t " .. HISTORY_DIR .. "/*.txt 2>/dev/null | head -" .. HISTORY_MAX)
  if not handle then return end
  for path in handle:lines() do
    local f = io.open(path, "r")
    if f then
      local text = f:read("*a") or ""
      f:close()
      local timePart = path:match("(%d%d%-%d%d%-%d%d)%.txt$") or "??-??-??"
      timePart = timePart:gsub("-", ":")
      table.insert(recentTranscriptions, {time = timePart, text = text})
    end
  end
  handle:close()
end

local function saveToHistory(text)
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  local path = HISTORY_DIR .. "/" .. stamp .. ".txt"
  local f = io.open(path, "w")
  if f then f:write(text); f:close() end
  table.insert(recentTranscriptions, 1, {time = os.date("%H:%M:%S"), text = text})
  while #recentTranscriptions > HISTORY_MAX do
    table.remove(recentTranscriptions)
  end
  refreshMenubar()
end

-- ─── Background recorder (continuous capture to rolling buffer) ──────────────
-- ffmpeg runs in the background writing to BUFFER_WAV. Restarts every
-- BG_CYCLE_SECS to bound the file size. This eliminates the per-recording
-- audio-device cold-start latency that was cutting off the first word.

local startBackgroundRecorder  -- forward declaration

startBackgroundRecorder = function()
  if bgShuttingDown then return end
  local dev = hs.audiodevice.defaultInputDevice()
  local devName = dev and dev:name() or "MacBook Pro Microphone"

  os.remove(BUFFER_WAV)
  bgStartEpoch = hs.timer.secondsSinceEpoch()

  bgRecorder = hs.task.new(FFMPEG, function(_exit, _out, _err)
    -- ffmpeg exited (either we killed it, OR it hit -t limit). Respawn unless shutting down.
    bgRecorder = nil
    if not bgShuttingDown then
      hs.timer.doAfter(0.05, startBackgroundRecorder)
    end
  end, {
    "-f", "avfoundation", "-i", ":" .. devName,
    "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
    "-t", tostring(BG_CYCLE_SECS),
    "-y", BUFFER_WAV
  })
  bgRecorder:start()
end

-- ─── Async transcribe + paste ────────────────────────────────────────────────
local function transcribeAndPaste(wavPath)
  local task = hs.task.new(WHISPER, function(exitCode, stdOut, _stdErr)
    hideTranscribingIndicator()
    if exitCode ~= 0 then return end
    local text = (stdOut or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 then return end

    saveToHistory(text)

    local prev = hs.pasteboard.getContents()
    hs.pasteboard.setContents(text)
    hs.osascript.applescript([[tell application "System Events" to keystroke "v" using command down]])
    hs.timer.doAfter(0.5, function()
      if prev then hs.pasteboard.setContents(prev) end
    end)
  end, {"-m", MODEL, "-f", wavPath, "-nt", "-np"})
  task:start()
end

-- Extract the relevant slice from the rolling buffer and pass to whisper.
-- pressEpoch / releaseEpoch are real-world epochs from hs.timer.secondsSinceEpoch().
local function extractAndTranscribe(pressEpoch, releaseEpoch)
  -- Compute offset within the current buffer file
  local startOffset = (pressEpoch - bgStartEpoch) - PRE_ROLL_SECS
  if startOffset < 0 then startOffset = 0 end
  local duration = (releaseEpoch - pressEpoch) + PRE_ROLL_SECS
  if duration < 0.2 then duration = 0.2 end  -- min sanity floor

  local snapshotPath = "/tmp/upscale-talk-" .. os.time() .. "-" .. math.random(1000, 9999) .. ".wav"

  -- Use ffmpeg to extract the slice from the buffer (copy codec — no re-encode)
  local extractCmd = string.format(
    "%s -ss %.3f -t %.3f -i %q -acodec copy %q 2>/dev/null",
    FFMPEG, startOffset, duration, BUFFER_WAV, snapshotPath
  )

  -- Run extraction async so we don't block; then transcribe on completion
  hs.task.new("/bin/sh", function(exitCode, _, _)
    if exitCode ~= 0 then
      hideTranscribingIndicator()
      return
    end
    transcribeAndPaste(snapshotPath)
    -- Clean up the snapshot after 5 min
    hs.timer.doAfter(300, function() os.remove(snapshotPath) end)
  end, {"-c", extractCmd}):start()
end

local function cancelPendingExtract()
  if pendingExtractTimer then
    pendingExtractTimer:stop()
    pendingExtractTimer = nil
  end
  hideTranscribingIndicator()
end

-- ─── Recording lifecycle (now just timestamp tracking + buffer extraction) ───
local function stopRec(releaseEpoch)
  if not recording then return end
  recording = false
  toggleMode = false
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  hideRecordingIndicator()
  showTranscribingIndicator()

  local pressEpoch = fnPressEpoch
  -- Schedule extraction (small delay so any in-flight buffer write completes)
  pendingExtractTimer = hs.timer.doAfter(0.15, function()
    pendingExtractTimer = nil
    extractAndTranscribe(pressEpoch, releaseEpoch)
  end)
end

local function startRec(asToggle)
  if recording then return end
  recording = true
  toggleMode = asToggle and true or false
  fnPressEpoch = hs.timer.secondsSinceEpoch()

  showRecordingIndicator(toggleMode)

  if not toggleMode then
    releaseWatchdog = hs.timer.doEvery(0.03, function()
      if toggleMode then return end
      local mods = hs.eventtap.checkKeyboardModifiers()
      if not mods.fn then
        stopRec(hs.timer.secondsSinceEpoch())
      end
    end)
  end
end

local function promoteToToggle()
  toggleMode = true
  if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
  showRecordingIndicator(true)
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
    stopRec(now)
    return false
  end

  if sinceLast < DOUBLE_TAP_WINDOW then
    cancelPendingExtract()
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

-- ─── Menubar setup ───────────────────────────────────────────────────────────
menubar = hs.menubar.new()
if menubar then
  menubar:setTitle("🎤")
  menubar:setTooltip("upscale-talk — recent transcriptions")
  loadHistoryFromDisk()
  refreshMenubar()
end

-- ─── Kick off the background recorder ────────────────────────────────────────
startBackgroundRecorder()

-- Clean shutdown on Hammerspoon exit/reload
hs.shutdownCallback = function()
  bgShuttingDown = true
  os.execute("pkill -9 -f 'ffmpeg.*upscale-talk' 2>/dev/null; true")
end

hs.alert.show("upscale-talk ready — hold fn (no startup lag now)", 2.0)
