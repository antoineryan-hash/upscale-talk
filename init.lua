-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Double-tap fn → toggle "locked" recording (hands-free); tap fn again to stop.
-- Every transcription is saved to ~/upscale-talk/history/ and reachable
-- via the 🎤 menubar icon (click to copy to clipboard).
-- Free, local-only Whisper push-to-talk dictation for macOS.
-- https://github.com/antoineryan-hash/upscale-talk
-- v0.5.5 - prefers the built-in mic over flaky Bluetooth; refuses to paste "you"
--          on a silent capture; optional opt-in usage counts (word totals only,
--          never your text - see the telemetry section below).

local VERSION = "0.5.5"
local HOME    = os.getenv("HOME")
local WAV     = "/tmp/upscale-talk.wav"
local MODEL   = HOME .. "/upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local HISTORY_DIR    = HOME .. "/upscale-talk/history"
local HISTORY_MAX    = 20      -- entries shown in menubar
local DOUBLE_TAP_WINDOW = 0.4

-- ─── Behaviour flags (safe to change) ────────────────────────────────────────
-- Bluetooth mics (AirPods etc.) frequently open via avfoundation but deliver a
-- SILENT stream, which makes Whisper hallucinate the word "you" on every take.
-- When the macOS default input is a Bluetooth device, record from the built-in
-- mic instead - it captures reliably and won't drop your AirPods into the
-- low-quality call profile. Set to false to always honour the macOS default.
local PREFER_BUILTIN_OVER_BLUETOOTH = true

-- If a recording comes back below this peak volume (dB), it's a dead capture -
-- don't paste the garbage transcription, show an alert explaining why instead.
-- Real speech peaks well above -70 dB; a silent avfoundation stream sits at -91.
local SILENCE_MAX_DB = -70

-- ─── Usage telemetry (OPT-IN, counts only, never your text) ──────────────────
-- If (and only if) you opted in during install, this sends a daily COUNT of how
-- many words you dictated - tagged with the first name you gave - so the team
-- can measure how useful the tool is. It NEVER sends any transcribed text, any
-- audio, or anything you said. Reads ~/upscale-talk/telemetry.conf:
--     name=<your first name>
--     enabled=true|false
-- No config file, or enabled=false -> nothing is ever sent. To stop sharing at
-- any time: set enabled=false in that file (or delete it) and reload Hammerspoon.
local TELEMETRY_ENDPOINT = "https://upscale-usage-production.up.railway.app/api/usage"
local TELEMETRY_TOKEN    = "upscale-talk-usage-v1"
local TELEMETRY_ENABLED  = false
local TELEMETRY_NAME     = "unknown"
do
  local f = io.open(HOME .. "/upscale-talk/telemetry.conf", "r")
  if f then
    for line in f:lines() do
      local k, v = line:match("^(%w+)%s*=%s*(.-)%s*$")
      if k == "enabled" then TELEMETRY_ENABLED = (v == "true") end
      if k == "name" and v and #v > 0 then
        TELEMETRY_NAME = v:gsub('[^%w _%-]', ''):sub(1, 40)  -- sanitise for safe JSON
      end
    end
    f:close()
  end
end

local recording              = false
local toggleMode             = false
local recordingTask          = nil
local releaseWatchdog        = nil
local pendingTranscribeTimer = nil
local lastFnDownTime         = 0
local currentDevName         = nil   -- the input device the live recording opened

-- Ensure history dir exists at startup
os.execute("mkdir -p " .. HISTORY_DIR)

-- (Calibration + warmup animation removed - simpler UX: red dot appears IFF
-- ffmpeg is actually capturing. User waits for the dot to appear, then talks.)

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

-- (Warmup indicator removed - see "ready-poll" in startRec instead. Nothing
-- on screen between fn-press and ffmpeg-ready; the red dot is the signal.)
local readyPoll = nil

local function cancelReadyPoll()
  if readyPoll then readyPoll:stop(); readyPoll = nil end
end

-- ─── Transcription history (menubar) ─────────────────────────────────────────
local menubar = nil
local recentTranscriptions = {}  -- [{time = "HH:MM:SS", text = "..."}]

local function refreshMenubar()
  if not menubar then return end
  local menu = {}
  if #recentTranscriptions == 0 then
    table.insert(menu, {title = "No transcriptions yet - hold fn to dictate", disabled = true})
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

    -- Save to history FIRST - so even if the paste lands in the wrong window,
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

-- Measure the peak volume of a WAV (async, ~150ms). Calls cb(maxDb) with a
-- number like -9.7, or nil if it couldn't be parsed. ffmpeg's volumedetect
-- prints "max_volume: -NN.N dB" to stderr.
local function measureMaxDb(wavPath, cb)
  local t = hs.task.new(FFMPEG, function(_exit, _out, stdErr)
    local maxDb = tonumber((stdErr or ""):match("max_volume:%s*(-?%d+%.?%d*) dB"))
    cb(maxDb)
  end, {"-i", wavPath, "-af", "volumedetect", "-f", "null", "-"})
  t:start()
end

-- The recording was silent. Don't paste "you" garbage - tell the user what
-- happened and how to fix it, tailored to whether the dead device was
-- Bluetooth or the built-in mic.
local function showSilenceAlert(devName)
  hs.alert.closeAll()
  local shown = devName or "your microphone"
  local msg = "🔇 No audio captured\n\n\"" .. shown .. "\" delivered silence."
  local lname = shown:lower()
  if lname:find("airpod") or lname:find("blue") or lname:find("buds")
     or lname:find("beats") or lname:find("headphone") then
    msg = msg .. "\nBluetooth mics often fail for recording.\n"
              .. "Fix: System Settings > Sound > Input,\n"
              .. "pick MacBook Pro Microphone, then try again."
  else
    msg = msg .. "\nCheck the mic isn't muted, and that\n"
              .. "Hammerspoon has Microphone permission\n"
              .. "(System Settings > Privacy > Microphone)."
  end
  hs.alert.show(msg, { textSize = 16 }, 7)
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
  cancelReadyPoll()
  hideRecordingIndicator()
  showTranscribingIndicator()

  local snapshotPath = "/tmp/upscale-talk-" .. os.time() .. "-" .. math.random(1000, 9999) .. ".wav"
  local devUsed = currentDevName
  pendingTranscribeTimer = hs.timer.doAfter(0.3, function()
    pendingTranscribeTimer = nil
    os.execute(string.format("mv %q %q 2>/dev/null", WAV, snapshotPath))
    -- Guard against dead/silent captures (Bluetooth avfoundation failures, a
    -- muted mic, revoked permission). Measure the peak first; only transcribe
    -- if there's real signal - otherwise alert instead of pasting "you".
    measureMaxDb(snapshotPath, function(maxDb)
      if maxDb ~= nil and maxDb < SILENCE_MAX_DB then
        hideTranscribingIndicator()
        showSilenceAlert(devUsed)
      else
        transcribeAndPaste(snapshotPath)
      end
    end)
    -- Keep WAVs around for 5 minutes (was 10s) - enough buffer to re-transcribe
    -- if something goes wrong, but bounded so /tmp doesn't fill up
    hs.timer.doAfter(300, function() os.remove(snapshotPath) end)
  end)
end

-- Pick which input device ffmpeg should open. Honours the macOS default input,
-- except when that default is a Bluetooth device and PREFER_BUILTIN_OVER_BLUETOOTH
-- is on - then redirect to the built-in mic (avfoundation captures it reliably).
local function looksBluetooth(dev)
  if not dev then return false end
  local t = dev.transportType and dev:transportType() or ""
  if type(t) == "string" and t:lower():find("blue") then return true end
  local n = (dev:name() or ""):lower()
  return n:find("airpod") ~= nil or n:find("buds") ~= nil or n:find("beats") ~= nil
      or n:find("headphone") ~= nil or n:find("wh%-") ~= nil or n:find("wf%-") ~= nil
end

local function looksBuiltin(dev)
  if not dev then return false end
  local t = dev.transportType and dev:transportType() or ""
  if type(t) == "string" and t:lower():find("built") then return true end
  local n = (dev:name() or ""):lower()
  return n:find("macbook") ~= nil and n:find("microphone") ~= nil
end

local function chooseInputDevice()
  local dev = hs.audiodevice.defaultInputDevice()
  local name = dev and dev:name() or "MacBook Pro Microphone"
  if PREFER_BUILTIN_OVER_BLUETOOTH and looksBluetooth(dev) then
    for _, d in ipairs(hs.audiodevice.allInputDevices()) do
      if looksBuiltin(d) then return d:name() end
    end
  end
  return name
end

local function startRec(asToggle)
  if recording then return end
  recording = true
  toggleMode = asToggle and true or false
  os.remove(WAV)

  -- No indicator yet - the red dot is the "you can speak now" signal.
  -- Nothing on screen between fn-press and ffmpeg actually capturing audio.

  local devName = chooseInputDevice()
  currentDevName = devName

  recordingTask = hs.task.new(FFMPEG, nil,
    {"-f", "avfoundation", "-i", ":" .. devName,
     "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1",
     "-flush_packets", "1",  -- flush each packet so the ready-poll can see growth
     "-y", WAV})
  recordingTask:start()

  -- Show the red recording dot the moment ffmpeg has actually written audio
  -- (WAV file size > header bytes). Until then, nothing on screen.
  -- 1.5s timeout fallback just in case polling can't tell.
  local pollStart = hs.timer.secondsSinceEpoch()
  readyPoll = hs.timer.doEvery(0.03, function()
    local attr = hs.fs.attributes(WAV)
    local size = attr and attr.size or 0
    local elapsed = hs.timer.secondsSinceEpoch() - pollStart
    if size > 100 or elapsed > 1.5 then
      cancelReadyPoll()
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
  -- If the ready-poll is still running, it'll create the red dot in locked
  -- mode on its own (it reads toggleMode). If the red dot is already up,
  -- re-render to add the white ring.
  if not readyPoll then
    showRecordingIndicator(true)
  end
end

-- ─── Usage reporting (opt-in; counts only) ───────────────────────────────────
-- Computes per-day {words, takes} for the last 14 days straight from the history
-- filenames/contents and POSTs them. No content ever leaves the machine. The
-- server keeps one row per (name, date) and overwrites it, so re-sending the
-- same window is harmless and any day the laptop was off gets backfilled the
-- next time it's on. Nothing here fires unless TELEMETRY_ENABLED is true.
local function reportUsage()
  if not TELEMETRY_ENABLED then return end
  if TELEMETRY_ENDPOINT == "TELEMETRY_" .. "ENDPOINT_URL" then return end  -- not yet wired at release

  -- Count words + takes per day over the last 14 days, in PURE LUA - no shell.
  -- (hs.execute's login shell runs multi-line pipelines unreliably across the
  -- varied shell setups on colleagues' Macs; reading the files directly is
  -- deterministic everywhere.)
  local cutoff = os.date("%Y%m%d", os.time() - 14 * 24 * 3600)  -- 14 days ago, YYYYMMDD
  local perDay = {}   -- ["YYYY-MM-DD"] = {words=, takes=}
  local ok = pcall(function()
    for file in hs.fs.dir(HISTORY_DIR) do
      local date = file:match("^(%d%d%d%d%-%d%d%-%d%d).*%.txt$")
      if date and (date:gsub("%-", "") >= cutoff) then
        local fh = io.open(HISTORY_DIR .. "/" .. file, "r")
        if fh then
          local text = fh:read("*a") or ""
          fh:close()
          local wc = 0
          for _ in text:gmatch("%S+") do wc = wc + 1 end
          local r = perDay[date] or { words = 0, takes = 0 }
          r.words = r.words + wc
          r.takes = r.takes + 1
          perDay[date] = r
        end
      end
    end
  end)
  if not ok then return end

  local days = {}
  for date, r in pairs(perDay) do
    days[#days + 1] = string.format('{"date":"%s","words":%d,"takes":%d}', date, r.words, r.takes)
  end
  if #days == 0 then return end

  local payload = string.format(
    '{"token":"%s","name":"%s","tool_version":"%s","days":[%s]}',
    TELEMETRY_TOKEN, TELEMETRY_NAME, VERSION, table.concat(days, ","))

  hs.http.asyncPost(TELEMETRY_ENDPOINT, payload,
    {["Content-Type"] = "application/json"},
    function(_status, _body, _headers) end)  -- fire and forget
end

if TELEMETRY_ENABLED then
  hs.timer.doAfter(20, reportUsage)             -- once, shortly after load/reload
  hs.timer.doEvery(6 * 60 * 60, reportUsage)    -- and every 6 hours while running
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
  menubar:setTooltip("upscale-talk - recent transcriptions")
  loadHistoryFromDisk()
  refreshMenubar()
end

hs.alert.show("upscale-talk ready - hold fn to dictate, double-tap fn to lock on", 2.0)
