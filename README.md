# upscale-talk

**Free, local-only Whisper push-to-talk dictation for macOS.**
Hold the **fn (Globe) key**, speak, release. Text pastes at your cursor in any app.

Built for the UpScale team. Replaces paid alternatives like VoiceInk Premium ($39) and Wispr Flow ($15/mo) with a single shell script + a 60-line Hammerspoon config. All processing happens on your Mac. Audio never leaves your machine.

## Requirements

- Mac with Apple Silicon (M1 or newer)
- macOS 13 or newer
- [Homebrew](https://brew.sh) installed
- ~600 MB free disk (Whisper model)

## Install

**Easiest way - one line in Terminal.** Open Terminal (Cmd+Space, type
"Terminal", Enter), paste this, press Enter, and follow the prompts:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/install.sh)"
```

That's the whole install (about 5 minutes). If you don't have Homebrew yet, it
offers to install that for you first. Because it's fetched with curl, macOS does
not show the "unverified developer" warning.

(Use `bash -c "$(curl ...)"`, not `curl ... | bash` - the pipe form can truncate
partway through because Homebrew reads from the same input stream.)

**Prefer to double-click?** Grab the zip, unzip it, double-click
**"Install upscale-talk.command"**. If your Mac blocks it with a malware
warning, see "0 READ ME FIRST - if your Mac blocks the installer.txt" in the
folder (the one-liner above avoids this entirely).

The installer:
1. Installs **Hammerspoon**, **whisper.cpp**, and **ffmpeg** via Homebrew
2. Downloads (or reuses VoiceInk's existing) **large-v3-turbo Q5_0** Whisper model (~547 MB)
3. Appends the Hammerspoon config to `~/.hammerspoon/init.lua` (preserves any existing config)
4. Disables macOS built-in dictation (avoids fn-key conflict)
5. Launches Hammerspoon

After the install runs, grant Hammerspoon three permissions in **System Settings → Privacy & Security**:

- **Accessibility** - lets it paste at the cursor in any app
- **Input Monitoring** - lets it listen for the fn key
- **Microphone** - lets it record what you say

Optional but recommended: **System Settings → Keyboard → Press 🌐 key to: Do Nothing** (prevents the emoji picker from briefly flashing on fn-press).

## Use

Hold **fn**. Speak. Release.

Text pastes at your cursor in:
- Claude Code
- Mail, Slack, Messages, Notes
- Browser URL/text fields
- Terminal, VS Code
- Anywhere you can paste

A small `🎤` appears while recording. A `⏳` appears while transcribing. Then your text lands.

## How it works

| Layer | Tool |
|---|---|
| fn-key listener | Hammerspoon `hs.eventtap` on flagsChanged events |
| Audio capture | `ffmpeg` recording 16-bit 16 kHz mono PCM |
| Transcription | `whisper-cli` (whisper.cpp) running the Q5_0 large-v3-turbo model locally |
| Paste | AppleScript Cmd+V via Hammerspoon, with clipboard restoration |

No cloud APIs. No subscriptions. No telemetry.

## Uninstall

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/antoineryan-hash/upscale-talk/main/uninstall.sh)"
```

This removes the Hammerspoon config block and the local Whisper model. It does NOT uninstall Hammerspoon, whisper.cpp, or ffmpeg (they may be used by other things on your Mac). Instructions to remove those are printed at the end of the uninstall.

## Troubleshooting

**"Apple could not verify ... is free of malware" when opening the installer.**
Normal for an unsigned script - nothing is wrong. Don't click "Move to Bin".
See **"0 READ ME FIRST - if your Mac blocks the installer.txt"** in this folder.
Short version: click Done, then System Settings > Privacy & Security > scroll
to the bottom > "Open Anyway", then double-click the installer again. Or run it
from Terminal: type `bash `, drag the .command file into the window, press Enter.

**"Nothing happens when I hold fn."**
Check that Hammerspoon is running (look for the hammer icon in the menu bar). Confirm Accessibility + Input Monitoring permissions are granted in System Settings → Privacy & Security.

**"Recording starts but no text appears."**
Open Hammerspoon → Console (menubar). Hold fn, speak, release. The console will print any errors. Common causes:
- Microphone permission not granted
- Whisper model path is wrong (check `ls ~/upscale-talk/models/`)
- `whisper-cli` not on PATH (`which whisper-cli` should print `/opt/homebrew/bin/whisper-cli`)

**"Text pastes into the wrong app."**
The paste targets whichever app is frontmost when you release fn. Make sure your text field is focused before holding fn.

**"Emoji picker keeps flashing when I press fn."**
Set **System Settings → Keyboard → Press 🌐 key to: Do Nothing**.

## License

MIT. See [LICENSE](LICENSE).
