-- upscale-talk: hold fn → speak → release → text pastes at cursor
-- Double-tap fn → MEETING mode: records BOTH your mic and the system audio
--   (the far side of a Zoom/Meet/in-person call) until you tap fn once to stop,
--   then produces a Jamie-style labelled transcript in ~/upscale-talk/meetings/.
-- Every dictation is saved to ~/upscale-talk/history/ and reachable
-- via the 🎤 menubar icon (click to copy to clipboard).
-- Free, local-only Whisper dictation + meeting transcription for macOS.
-- https://github.com/antoineryan-hash/upscale-talk
-- v0.6.1 - self-heals Whisper repetition-loop hallucinations: if a dictation
--          comes back looped, it auto re-transcribes once with -mc 0 (the fix)
--          before pasting. Plus v0.6.0 meeting mode (Core Audio tap for system
--          audio + mic, channel-split "you vs them" diarisation, post-meeting
--          speaker naming with a growing voice library). Dictation otherwise
--          unchanged: prefers built-in over flaky Bluetooth, refuses to paste
--          "you" on a silent capture, opt-in counts.

local VERSION = "0.6.2"
pcall(function() require("hs.ipc") end)  -- enable the `hs` command-line tool (support/validation)
local HOME    = os.getenv("HOME")
local WAV     = "/tmp/upscale-talk.wav"
local MODEL   = HOME .. "/upscale-talk/models/ggml-large-v3-turbo-q5_0.bin"
local FFMPEG  = "/opt/homebrew/bin/ffmpeg"
local WHISPER = "/opt/homebrew/bin/whisper-cli"

local HISTORY_DIR    = HOME .. "/upscale-talk/history"
local HISTORY_MAX    = 20      -- entries shown in menubar
local DOUBLE_TAP_WINDOW = 0.4
local MEETING_RESTART_COOLDOWN = 2.0  -- seconds; ignore fn taps just after stopping so a double-tap-to-stop can't immediately restart

-- ─── Meeting mode (double-tap fn) ────────────────────────────────────────────
-- Installed helper/script locations (install.sh copies the repo's helpers/bin
-- and scripts here, alongside models/ and history/).
local MEETINGS_DIR = HOME .. "/upscale-talk/meetings"
local VOICES_DIR   = HOME .. "/upscale-talk/voices"     -- reference voice library
local BIN_DIR      = HOME .. "/upscale-talk/bin"
local SCRIPTS_DIR  = HOME .. "/upscale-talk/scripts"
local TAP_CAPTURE  = BIN_DIR .. "/capture-system.sh"    -- audiotee → them.wav
local MIC_CAPTURE  = BIN_DIR .. "/capture-mic.sh"       -- your mic → me.wav
local MEETING_HEARTBEAT   = HOME .. "/upscale-talk/.heartbeat"
-- Hard ceiling on one recording, enforced inside the capture wrappers so it
-- survives Hammerspoon dying. Longest real meeting on disk is 77 minutes.
local MEETING_MAX_SECONDS = 10800   -- 3 hours
local MEETING_TRANSCRIBE = SCRIPTS_DIR .. "/meeting_transcribe.py"
local NAME_SPEAKERS      = SCRIPTS_DIR .. "/name_speakers.py"
local LLM_DIARISE        = SCRIPTS_DIR .. "/llm_diarise.py"
local PYTHON3      = "/usr/bin/python3"                  -- has whisper + resemblyzer
local MEETING_ME_NAME = "Antoine"                       -- label for your mic channel
local MEETING_SPEAKERS = 2  -- people sharing ONE mic in-person (set 3+ for a bigger room).
                            -- Remote calls + dual-mic ignore this. Single-mic auto-count
                            -- is unreliable, so we fix it; 2 suits 1:1s.

-- Meeting mode is only active if its helper + pipeline are installed
-- (helpers/setup-meeting-mode.sh). If not, double-tap falls back to the original
-- locked hands-free dictation — so this same config is safe for colleagues who
-- only ran the dictation one-liner.
local MEETING_AVAILABLE = (hs.fs.attributes(TAP_CAPTURE) ~= nil)
                          and (hs.fs.attributes(MIC_CAPTURE) ~= nil)
                          and (hs.fs.attributes(MEETING_TRANSCRIBE) ~= nil)

-- A half-installed meeting mode is worse than none: the tap helper is there but
-- the mic wrapper (and its duration cap) is not. Say so rather than silently
-- reverting to dictation on a double-tap.
local MEETING_NEEDS_UPDATE = (hs.fs.attributes(TAP_CAPTURE) ~= nil)
                             and (hs.fs.attributes(MIC_CAPTURE) == nil)

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

-- Meeting-mode state
local meetingActive  = false
local meetingDir     = nil
local meetingTapTask = nil   -- capture-system.sh (system audio via Core Audio tap)
local meetingMicTask = nil   -- ffmpeg (your mic)
local meetingStartedAt = 0
local meetingStoppedAt = 0
-- Forward declaration. The menubar needs to call stopMeeting, and the menubar is
-- built long before stopMeeting is defined. Until now the fn event tap was the
-- ONLY caller of stopMeeting anywhere in this file, so a dead event tap meant a
-- meeting that could not be stopped at all.
local stopMeeting
local meetingHeartbeat = nil  -- hs.timer keeping ~/upscale-talk/.heartbeat fresh
local meetingFinaliseTimer = nil  -- held, like pendingTranscribeTimer, not left loose

-- Ensure working dirs exist at startup
os.execute("mkdir -p " .. HISTORY_DIR)
os.execute(string.format("mkdir -p %q %q", MEETINGS_DIR, VOICES_DIR))

-- (Calibration + warmup animation removed - simpler UX: red dot appears IFF
-- ffmpeg is actually capturing. User waits for the dot to appear, then talks.)

-- Kill any orphan ffmpeg processes left from a previous Hammerspoon session
-- (cold-restart can detach our child ffmpeg, leaving it recording forever).
-- Scoped to the two CAPTURE outputs. The old pattern 'ffmpeg.*upscale-talk'
-- also matched every ffmpeg inside meeting_transcribe.py, so a Hammerspoon
-- reload during a post-meeting transcription used to kill the transcription.
os.execute("pkill -9 -f 'ffmpeg.*/tmp/upscale-talk.wav' 2>/dev/null; true")
os.execute("pkill -9 -f 'ffmpeg.*upscale-talk/meetings/.*/me.wav' 2>/dev/null; true")
-- Same for any orphaned meeting capture (system-audio tap) from a previous run
os.execute("pkill -9 -f 'capture-system.sh' 2>/dev/null; pkill -9 -f 'helpers/bin/audiotee' 2>/dev/null; pkill -9 -f 'upscale-talk/bin/audiotee' 2>/dev/null; true")

-- ─── Stopping a capture ──────────────────────────────────────────────────────
-- terminate() sends SIGTERM, which ffmpeg IGNORES while it is reading from
-- avfoundation (see 3356c24, 17 May). So follow it with SIGKILL on the task's
-- OWN pid.
--
-- By pid, never by name. 'ffmpeg.*upscale-talk' also matched the system-audio
-- wrapper's ffmpeg (its argv holds .../them.wav), measureMaxDb's ffmpeg, and
-- every ffmpeg inside meeting_transcribe.py - so stopping a dictation while a
-- meeting was still transcribing SIGKILLed the transcription, and a kill fired
-- at stop time raced the wrapper that has to finalise them.wav cleanly.
local function stopTask(task)
  if not task then return end
  local running = task:isRunning()
  local pid = task:pid()
  task:terminate()
  -- Only signal a pid we know was live a moment ago. pid() keeps returning the
  -- number after a task has exited, and blind-killing a stale pid can hit an
  -- unrelated process that inherited it.
  if running and pid and pid > 0 then
    os.execute("kill -9 " .. pid .. " 2>/dev/null; true")
  end
end

-- The system-audio wrapper finalises them.wav inside its SIGTERM trap, so it
-- must be allowed to exit on its own. Escalate only if it is still alive well
-- after the trap should have run.
local function stopWrapperTask(task)
  if not task then return end
  local pid = task:pid()
  task:terminate()
  if not (pid and pid > 0) then return end
  hs.timer.doAfter(2.0, function()
    if task:isRunning() then
      os.execute("kill -9 " .. pid .. " 2>/dev/null; true")
    end
  end)
end

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

-- ─── Meeting indicator (pulsing BLUE dot with ring — distinct from dictation) ─
local BLUE = {red = 0.15, green = 0.50, blue = 1.00}
local meetIndicator  = nil
local meetPulseTimer = nil

local function showMeetingIndicator()
  if meetIndicator then meetIndicator:delete() end
  if meetPulseTimer then meetPulseTimer:stop(); meetPulseTimer = nil end
  meetIndicator = hs.canvas.new(indicatorFrame())
  meetIndicator:level(hs.canvas.windowLevels.overlay)
  meetIndicator:behavior({"canJoinAllSpaces", "stationary"})
  local center = {x = INDICATOR_SIZE / 2, y = INDICATOR_SIZE / 2}
  meetIndicator[1] = {
    type = "circle", action = "fill",
    fillColor = {red = BLUE.red, green = BLUE.green, blue = BLUE.blue, alpha = 1.0},
    radius = INDICATOR_SIZE / 2 - 3, center = center,
  }
  meetIndicator[2] = {
    type = "circle", action = "stroke",
    strokeColor = {white = 1.0, alpha = 0.9}, strokeWidth = 1.5,
    radius = INDICATOR_SIZE / 2 - 1, center = center,
  }
  meetIndicator:show()
  local t0 = hs.timer.secondsSinceEpoch()
  meetPulseTimer = hs.timer.doEvery(0.04, function()
    if not meetIndicator then return end
    local a = pulseAlpha(t0, 1.6, 0.40, 1.0)
    meetIndicator[1].fillColor = {red = BLUE.red, green = BLUE.green, blue = BLUE.blue, alpha = a}
  end)
end

local function hideMeetingIndicator()
  if meetPulseTimer then meetPulseTimer:stop(); meetPulseTimer = nil end
  if meetIndicator then meetIndicator:delete(); meetIndicator = nil end
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

-- Count meetings that hold audio but never produced a transcript. Before
-- v0.6.2 an interrupted meeting vanished silently: meetingDir is a module local
-- that dies with the process, so nothing ever mentioned it again. This is the
-- visible half of the duration cap - a capped meeting surfaces here rather than
-- disappearing.
local updateAvailable  -- set by the once-a-day version check near the bottom
local function unfinishedMeetings()
  local n, bytes = 0, 0
  local h = io.popen("ls -1 " .. MEETINGS_DIR .. " 2>/dev/null")
  if not h then return 0, 0 end
  for name in h:lines() do
    local dir = MEETINGS_DIR .. "/" .. name
    if hs.fs.attributes(dir .. "/transcript.txt") == nil then
      local size = 0
      for _, w in ipairs({"me.wav", "them.wav"}) do
        local a = hs.fs.attributes(dir .. "/" .. w)
        if a then size = size + a.size end
      end
      if size > 0 then n = n + 1; bytes = bytes + size end
    end
  end
  h:close()
  return n, bytes
end

-- What this install is and what it is doing. Goes in the clipboard and in the
-- feedback email; nothing here is a transcript or a word of anyone's audio.
local function diagnostics()
  local unfin = unfinishedMeetings()
  local agent = "no"
  local h = io.popen("launchctl list 2>/dev/null | grep -c upscale-talk-autostart")
  if h then if (tonumber(h:read("*a")) or 0) > 0 then agent = "yes" end; h:close() end
  local osv = "?"
  local o = io.popen("sw_vers -productVersion 2>/dev/null")
  if o then osv = (o:read("*l") or "?"); o:close() end
  return table.concat({
    "upscale-talk " .. VERSION,
    "macOS " .. osv,
    "start at login: " .. agent,
    "meeting mode: " .. (MEETING_AVAILABLE and "yes" or "no"),
    "meetings with no transcript: " .. tostring(unfin),
    "", "--- what happened? ---", "",
  }, "\n")
end

local function refreshMenubar()
  if not menubar then return end
  local menu = {}
  -- A second way out. If the fn event tap is dead (a revoked Accessibility
  -- grant after a macOS update, or a wedged tap) this is the only thing that can
  -- end a recording short of quitting Hammerspoon.
  if meetingActive then
    local mins = math.floor((hs.timer.secondsSinceEpoch() - meetingStartedAt) / 60)
    table.insert(menu, {
      title = "■  Stop meeting  (recording " .. mins .. " min)",
      fn = function() if stopMeeting then stopMeeting() end end,
    })
    table.insert(menu, {title = "-"})
  end
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
  -- Recent meetings (double-tap fn). Paths here are timestamped dirs with no
  -- spaces/quotes, so plain single-quoting is safe.
  local mlines = {}
  local mh = io.popen("ls -t " .. MEETINGS_DIR .. " 2>/dev/null | head -8")
  if mh then for name in mh:lines() do mlines[#mlines + 1] = name end; mh:close() end
  if #mlines > 0 then
    table.insert(menu, {title = "-"})
    table.insert(menu, {title = "Recent meetings (click to open transcript)", disabled = true})
    for _, name in ipairs(mlines) do
      local dir = MEETINGS_DIR .. "/" .. name
      table.insert(menu, {
        title = "🎦  " .. name,
        fn = function()
          local tpath = dir .. "/transcript.txt"
          local target = hs.fs.attributes(tpath) and tpath or dir
          hs.execute("open '" .. target .. "'")
        end,
      })
    end
  end

  table.insert(menu, {title = "-"})
  table.insert(menu, {
    title = "Open Meetings Folder…",
    fn = function() hs.execute("open " .. MEETINGS_DIR) end,
  })
  table.insert(menu, {
    title = "Open History Folder…",
    fn = function() hs.execute("open " .. HISTORY_DIR) end,
  })

  local unfin, unfinBytes = unfinishedMeetings()
  if unfin > 0 then
    table.insert(menu, {
      title = string.format("⚠️  %d meeting%s never transcribed (%.1f GB)…",
                            unfin, unfin == 1 and "" or "s", unfinBytes / 1e9),
      fn = function() hs.execute("open " .. MEETINGS_DIR) end,
    })
  end

  -- Every tool gets a way to report a problem. This one has no web page, so it
  -- opens a pre-filled email instead of posting anywhere: nothing leaves the Mac
  -- until the person presses send, and the body is only the lines below - no
  -- transcript, no audio, no history.
  table.insert(menu, {title = "-"})
  table.insert(menu, {
    title = "Report a problem…",
    fn = function()
      local body = diagnostics()
      hs.pasteboard.setContents(body)
      local url = "mailto:antoine@up-scale.me?subject=" ..
        hs.http.encodeForQuery("upscale-talk " .. VERSION .. " - " .. (hs.host.localizedName() or "")) ..
        "&body=" .. hs.http.encodeForQuery(body)
      local opened = hs.urlevent.openURL(url)
      if not opened then
        hs.alert.show("Couldn't open your mail app.\nDiagnostics copied - email antoine@up-scale.me", 6)
      end
    end,
  })
  table.insert(menu, {
    title = "Copy diagnostics",
    fn = function()
      hs.pasteboard.setContents(diagnostics())
      hs.alert.show("📋 Diagnostics copied", 1)
    end,
  })
  if updateAvailable then
    table.insert(menu, {
      title = "⬆︎  Update available (" .. updateAvailable .. ") - click to copy the command",
      fn = function()
        local cmd = 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/' ..
                    'antoineryan-hash/upscale-talk/main/install.sh)"'
        hs.pasteboard.setContents(cmd)
        hs.alert.show("📋 Copied. Paste it into Terminal and press Enter.", 4)
      end,
    })
  end
  table.insert(menu, {
    title = "upscale-talk " .. VERSION ..
            (MEETING_AVAILABLE and "  ·  meeting mode on" or ""),
    disabled = true,
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
-- Detect a Whisper repetition-loop hallucination: the model gets stuck repeating
-- a phrase and collapses the rest of a (usually longer) take. Pure-Lua check on
-- the text we already have — microseconds, so it runs on every dictation. When
-- it fires we re-transcribe ONCE with -mc 0 (no context carry-over), which is
-- the known fix for whisper.cpp loops. Normal dictations pay nothing.
local function looksLikeLoop(text)
  if not text or #text < 40 then return false end
  -- The same >=3-word sentence repeated 3+ times → loop.
  local counts, maxrep = {}, 0
  for sentence in text:gmatch("[^%.%!%?]+") do
    local s = sentence:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    local wc = 0
    for _ in s:gmatch("%S+") do wc = wc + 1 end
    if wc >= 3 then
      counts[s] = (counts[s] or 0) + 1
      if counts[s] > maxrep then maxrep = counts[s] end
    end
  end
  if maxrep >= 3 then return true end
  -- Fallback: a long transcript with a very low unique-word ratio is a loop.
  local total, uniq, u = 0, {}, 0
  for w in text:lower():gmatch("%a+") do
    total = total + 1
    if not uniq[w] then uniq[w] = true; u = u + 1 end
  end
  return total >= 40 and (u / total) < 0.35
end

local function transcribeAndPaste(wavPath, isRetry)
  local args = {"-m", MODEL, "-f", wavPath, "-nt", "-np"}
  if isRetry then args[#args + 1] = "-mc"; args[#args + 1] = "0" end  -- loop-breaker
  local task = hs.task.new(WHISPER, function(exitCode, stdOut, _stdErr)
    if exitCode ~= 0 then hideTranscribingIndicator(); return end
    local text = (stdOut or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #text == 0 then hideTranscribingIndicator(); return end

    -- Self-heal a hallucination loop: re-transcribe once with -mc 0, use that.
    if (not isRetry) and looksLikeLoop(text) then
      transcribeAndPaste(wavPath, true)
      return
    end
    hideTranscribingIndicator()

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
  end, args)
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
  stopTask(recordingTask)
  recordingTask = nil
  -- Orphan sweep for a capture left by a PREVIOUS Hammerspoon session, where
  -- there is no pid to target. Scoped to the dictation WAV.
  os.execute("pkill -9 -f 'ffmpeg.*/tmp/upscale-talk.wav' 2>/dev/null; true")
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

-- ─── Meeting lifecycle (double-tap fn → record until next fn tap) ─────────────
local function shellQuote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- For meetings, capture the mic the user is ACTUALLY speaking into (often a
-- Bluetooth headset) — unlike dictation, do NOT force the built-in mic here.
local function meetingMicDevice()
  local dev = hs.audiodevice.defaultInputDevice()
  return dev and dev:name() or "MacBook Pro Microphone"
end

local function promptNameSpeakers(dir)
  -- name_speakers.py needs a TTY (afplay snippets + typed answers) → run in Terminal.
  local cmd = PYTHON3 .. " " .. shellQuote(NAME_SPEAKERS) .. " " .. shellQuote(dir)
  hs.osascript.applescript(string.format(
    'tell application "Terminal"\nactivate\ndo script %s\nend tell', shellQuote(cmd)))
end

local function runMeetingPipeline(dir)
  -- Run through a login shell so ffmpeg (brew) + python deps resolve as normal.
  local transcribeCmd = table.concat({
    shellQuote(PYTHON3), shellQuote(MEETING_TRANSCRIBE), shellQuote(dir),
    "--me-name", shellQuote(MEETING_ME_NAME),
    "--speakers", tostring(MEETING_SPEAKERS),
  }, " ")
  local llmCmd = table.concat({
    shellQuote(PYTHON3), shellQuote(LLM_DIARISE), shellQuote(dir),
    "--calendar-roster", "--auto-roster", "--as-primary",
  }, " ")
  local cmd = transcribeCmd .. " && { " .. llmCmd .. " || true; }"
  local t = hs.task.new("/bin/zsh", function(exitCode, stdOut, stdErr)
    hideTranscribingIndicator()
    if exitCode ~= 0 then
      hs.alert.show("⚠️ Meeting transcription failed.\n" .. ((stdErr or ""):sub(1, 200)), 6)
      return
    end
    refreshMenubar()
    hs.alert.show("✅ Meeting transcript ready\n" .. dir, 4)
    if (stdOut or ""):find("UNNAMED") then promptNameSpeakers(dir) end
  end, {"-lc", cmd})
  t:start()
end

local function startMeeting()
  if meetingActive or recording then return end
  meetingActive = true
  meetingStartedAt = hs.timer.secondsSinceEpoch()
  local stamp = os.date("%Y-%m-%d_%H-%M-%S")
  meetingDir = MEETINGS_DIR .. "/" .. stamp
  os.execute(string.format("mkdir -p %q", meetingDir))

  -- Heartbeat: both capture wrappers stop themselves if this goes stale, so a
  -- meeting cannot outlive Hammerspoon or a stop path that never ran.
  os.execute(string.format("touch %q", MEETING_HEARTBEAT))
  meetingHeartbeat = hs.timer.doEvery(30, function()
    os.execute(string.format("touch %q", MEETING_HEARTBEAT))
  end)

  -- System audio (the far side) via the Core Audio tap wrapper.
  meetingTapTask = hs.task.new("/bin/bash", nil,
    {TAP_CAPTURE, meetingDir .. "/them.wav",
     tostring(MEETING_MAX_SECONDS), MEETING_HEARTBEAT})
  meetingTapTask:start()

  -- Your mic — honour the current default input (headset), don't force built-in.
  -- Capture 2 channels: a 2-mic device (e.g. Rode, one lav per person) lands each
  -- person on their own channel for clean diarisation; a mono mic just duplicates
  -- (the pipeline detects that and falls back). ffmpeg errors if the device has
  -- fewer channels than asked, so probe channel support isn't needed: avfoundation
  -- upmixes a mono source to the requested 2 channels.
  -- Run through capture-mic.sh rather than ffmpeg directly. The wrapper splits
  -- capture from writing across a fifo, so however the capture is killed the
  -- writer still sees EOF and finalises a valid WAV header - every me.wav before
  -- this carried a placeholder size, which is what meeting_transcribe.py and
  -- calendar_roster.py had to work around in 3854c2b. It also owns the duration
  -- cap and the heartbeat guard.
  local mic = meetingMicDevice()
  meetingMicTask = hs.task.new("/bin/bash", nil,
    {MIC_CAPTURE, meetingDir .. "/me.wav", tostring(mic),
     tostring(MEETING_MAX_SECONDS), MEETING_HEARTBEAT})
  meetingMicTask:start()

  showMeetingIndicator()
  refreshMenubar()
  hs.alert.show("🔵 Meeting recording — tap fn once to stop", 2.5)
end

function stopMeeting()
  if not meetingActive then return end
  meetingActive = false
  meetingStoppedAt = hs.timer.secondsSinceEpoch()
  local dir = meetingDir
  meetingDir = nil

  -- Stop the capture FIRST, and under pcall.
  --
  -- This used to clear meetingActive and tear the indicator down BEFORE anything
  -- was killed. An error in that teardown left both recordings running AND the
  -- meeting unstoppable: with meetingActive already false, every later fn press
  -- falls through to the dictation path, so there was no way back. Ordering the
  -- kill first, and isolating it, means a UI failure can no longer cost a
  -- recording.
  --
  -- Both captures are wrappers, so SIGTERM reaches their trap, which stops the
  -- capture and waits for the writer to finalise a valid WAV. stopWrapperTask
  -- escalates to SIGKILL after 2s if one is wedged.
  local ok, err = pcall(function()
    if meetingHeartbeat then meetingHeartbeat:stop(); meetingHeartbeat = nil end
    stopWrapperTask(meetingMicTask); meetingMicTask = nil
    stopWrapperTask(meetingTapTask); meetingTapTask = nil
  end)
  if not ok then
    -- No pids to work with. Fall back to the wrapper names, politely, so their
    -- traps still run and both WAVs still finalise.
    os.execute("pkill -f 'capture-mic.sh' 2>/dev/null; pkill -f 'capture-system.sh' 2>/dev/null; true")
    hs.printf("upscale-talk: stopMeeting cleanup failed (%s) - fell back to pkill", tostring(err))
  end

  pcall(hideMeetingIndicator)
  pcall(showTranscribingIndicator)
  pcall(refreshMenubar)
  hs.alert.show("Meeting ended - transcribing...", 2)
  -- Let both capture wrappers finalise their WAVs, then process. This has to
  -- outlast stopWrapperTask's 2.0s escalation, or the pipeline can start reading
  -- a WAV that is still being written - which is how a 28.8 minute meeting came
  -- back as a 23.1 minute transcript with no error (2026-08-10).
  meetingFinaliseTimer = hs.timer.doAfter(3.0, function()
    -- Warn if the mic channel came back silent (e.g. Bluetooth capture failure).
    -- The far side is captured via the tap regardless, so the meeting isn't lost.
    measureMaxDb(dir .. "/me.wav", function(maxDb)
      if maxDb ~= nil and maxDb < SILENCE_MAX_DB then
        hs.alert.show("⚠️ Your mic was silent this meeting (Bluetooth?).\nThe other side was still captured.", 6)
      end
    end)
    runMeetingPipeline(dir)
  end)
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

  -- Meeting in progress → any fn press stops it.
  if meetingActive then
    stopMeeting()
    return false
  end

  if toggleMode then
    stopRec()
    return false
  end

  if sinceLast < DOUBLE_TAP_WINDOW then
    if hs.timer.secondsSinceEpoch() - meetingStoppedAt < MEETING_RESTART_COOLDOWN then
      return false
    end
    cancelPendingTranscribe()
    if MEETING_NEEDS_UPDATE then
      hs.alert.show("Meeting mode needs updating.\nRun helpers/setup-meeting-mode.sh from the repo,\nthen reload Hammerspoon.", 6)
      return false
    end
    if MEETING_AVAILABLE then
      -- Double-tap fn = MEETING mode. The first tap may have optimistically
      -- started a hold-dictation; abandon it (WITHOUT transcribing) and start
      -- the meeting instead.
      if recording then
        recording = false
        toggleMode = false
        if releaseWatchdog then releaseWatchdog:stop(); releaseWatchdog = nil end
        stopTask(recordingTask); recordingTask = nil
        cancelReadyPoll()
        hideRecordingIndicator()
        os.remove(WAV)
      end
      startMeeting()
    else
      -- Fallback (dictation-only install): original locked hands-free recording.
      if recording then promoteToToggle() else startRec(true) end
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

hs.alert.show("upscale-talk ready - hold fn to dictate, double-tap fn to " ..
  (MEETING_AVAILABLE and "record a meeting" or "lock on"), 2.5)

-- ─── Start at login: repair it if it is missing ──────────────────────────────
-- The agent was added to install.sh on 2026-08-20 and never to the
-- double-click installer, so every zip install lost the tool at its next
-- restart with no error. Tom Gibson's "mine's not working" on 13 August was
-- almost certainly this. The remedy shipped that day was a one-liner sent to
-- eight people, and exactly one machine was ever confirmed.
--
-- So repair it here instead of asking. Idempotent, same plist install.sh
-- writes, and it runs once per Hammerspoon load. Delete the agent AND create
-- ~/upscale-talk/.no-autostart if you want it to stay gone.
local function ensureAutostart()
  local label = "com.upscale.upscale-talk-autostart"
  local plist = HOME .. "/Library/LaunchAgents/" .. label .. ".plist"
  if hs.fs.attributes(HOME .. "/upscale-talk/.no-autostart") ~= nil then return end
  if hs.fs.attributes(plist) ~= nil then return end

  local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>]] .. label .. [[</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>Hammerspoon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
]]
  os.execute(string.format("mkdir -p %q", HOME .. "/Library/LaunchAgents"))
  local f = io.open(plist, "w")
  if not f then return end
  f:write(xml); f:close()

  -- Lint before loading it, and remove it again if it is not valid, rather
  -- than leaving a broken plist behind.
  if os.execute(string.format("plutil -lint %q >/dev/null 2>&1", plist)) then
    os.execute(string.format(
      "launchctl bootout gui/$(id -u)/%s >/dev/null 2>&1; " ..
      "launchctl bootstrap gui/$(id -u) %q >/dev/null 2>&1; true", label, plist))
    hs.printf("upscale-talk: start-at-login was missing; installed %s", label)
  else
    os.remove(plist)
  end
end
ensureAutostart()

-- ─── Is there a newer version? ───────────────────────────────────────────────
-- Reads one public file. No name, no token, nothing identifying is sent, and
-- nothing updates itself - it only tells you the command to run. Set
-- updates=off in ~/upscale-talk/telemetry.conf to skip it.
local function checkForUpdate()
  local conf = io.open(HOME .. "/upscale-talk/telemetry.conf", "r")
  if conf then
    local body = conf:read("*a") or ""; conf:close()
    if body:find("updates%s*=%s*off") then return end
  end
  hs.http.asyncGet(
    "https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/VERSION",
    nil,
    function(status, body)
      if status ~= 200 or not body then return end
      local latest = body:gsub("%s", "")
      if latest ~= "" and latest ~= VERSION then
        updateAvailable = latest
        refreshMenubar()
      end
    end)
end
hs.timer.doAfter(45, checkForUpdate)
hs.timer.doEvery(24 * 3600, checkForUpdate)

-- ─── Support handle ──────────────────────────────────────────────────────────
-- hs.ipc is already enabled at the top of this file, so `hs -c "..."` can reach
-- anything exposed here. Everything else in this config is `local`, which meant
-- the stop path could not be exercised at all except by a physical fn keypress -
-- no test, no emergency stop, no way for a colleague to confirm a fix.
--
--   hs -c "utDebug.stop()"             end a meeting that will not end
--   hs -c "utDebug.status()"           what this install is and what it is doing
--   hs -c "utDebug.start()"            start a meeting without touching the keyboard
--
-- scripts/selftest-meeting.sh drives the whole stop path through these.
utDebug = {
  version  = VERSION,
  start    = function() startMeeting() end,
  stop     = function() stopMeeting() end,
  status   = function()
    return string.format(
      "version=%s meeting_available=%s meeting_active=%s recording=%s dir=%s",
      VERSION, tostring(MEETING_AVAILABLE), tostring(meetingActive),
      tostring(recording), tostring(meetingDir))
  end,
  meetingActive = function() return meetingActive end,
  -- Same text the menubar's "Copy diagnostics" produces, so it can be checked
  -- from the command line without clicking anything.
  diagnostics   = function() return diagnostics() end,
}
