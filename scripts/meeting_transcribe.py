#!/usr/bin/env python3
"""
meeting_transcribe.py <meeting_dir>

Turns a two-stream meeting recording into a Jamie-style labelled transcript.

Expects in <meeting_dir>:
    me.wav      your microphone (you)
    them.wav    system audio  (everyone else, captured via the Core Audio tap)

Produces:
    transcript.txt   Jamie-style blocks:  Speaker \\n MM:SS - MM:SS \\n text
    transcript.json  unified [{start,end,speaker,text}] sorted by start
    them/them.json   diarised far-side segments (from the video-transcriber skill)

Channel split = free 2-way diarisation: your mic is always you; the far side is
diarised into distinct voices and auto-named from the reference library
(~/upscale-talk/voices) when a voice is recognised (cosine >= 0.75), else
"Speaker N" (name them afterwards with name_speakers.py).

The 'me' channel is transcribed with whisper-cli (large-v3-turbo, GPU-fast).
The 'them' channel is transcribed + diarised by the video-transcriber script
(openai-whisper + resemblyzer). See --model to trade speed vs accuracy there.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
WHISPER_MODEL = os.path.join(HOME, "upscale-talk/models/ggml-large-v3-turbo-q5_0.bin")
DIARISE_SCRIPT = os.path.join(
    HOME, ".claude/skills/video-transcriber/scripts/transcribe_with_speakers.py"
)


SILENCE_MAX_DB = -70.0   # a channel below this peak is a dead/silent capture

# Whisper's stock hallucinations on silent/near-silent audio. Dropped only when
# they are the ENTIRE segment text (so real speech containing these is untouched).
PHANTOMS = {"you", "you.", "thank you.", "thank you", "thanks for watching.",
            "thanks for watching", "[blank_audio]", "bye.", ""}


def mmss(seconds):
    """Whole-minutes:seconds, allowing minutes > 59 (e.g. 74:05) to match Jamie."""
    s = int(round(seconds))
    return f"{s // 60:02d}:{s % 60:02d}"


def is_phantom(text):
    return text.strip().lower() in PHANTOMS


def is_loop(text):
    """Whisper repetition-loop hallucination: a phrase repeated many times, or a
    long transcript with very few unique words. Mirrors the dictation guard."""
    if not text or len(text) < 40:
        return False
    counts = {}
    for s in re.split(r"[.!?]+", text):
        s = s.strip().lower()
        if len(s.split()) >= 3:
            counts[s] = counts.get(s, 0) + 1
    if counts and max(counts.values()) >= 3:
        return True
    words = re.findall(r"[a-z]+", text.lower())
    return len(words) >= 40 and len(set(words)) / len(words) < 0.35


def _whisper_cli(wav, out_base, mc0=False):
    args = [WHISPER_CLI, "-m", WHISPER_MODEL, "-f", wav, "-oj", "-of", out_base]
    if mc0:
        args += ["-mc", "0"]   # break repetition loops
    subprocess.run(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    return json.load(open(out_base + ".json"))


def _tokens(text):
    return set(re.findall(r"[a-z0-9']+", text.lower()))


def dedupe_mic_bleed(me, them, slack=2.0, contain=0.6):
    """Remove mic-channel echo of the far side (happens when on speakers, not a
    headset: your mic picks up the far side playing through the speakers).

    Your own voice is ONLY ever on the mic and never in the system-audio tap, so
    it can't be dropped. A mic segment is treated as bleed — and removed — only
    when most of its words also appear in a far-side segment overlapping it in
    time. On a headset there's no bleed, so nothing overlaps and nothing drops.
    """
    kept, dropped = [], 0
    for m in me:
        window = " ".join(
            t["text"] for t in them
            if not (t["end"] < m["start"] - slack or t["start"] > m["end"] + slack)
        )
        mt = _tokens(m["text"])
        if mt and window:
            if len(mt & _tokens(window)) / len(mt) >= contain:
                dropped += 1
                continue
        kept.append(m)
    return kept, dropped


def collapse_repeats(text):
    """Drop consecutive duplicate sentences — kills Whisper repetition-loop tails
    (e.g. 'I'm so excited.' x28) that slip through the diarisation engine."""
    out = []
    for p in re.split(r"(?<=[.!?])\s+", text):
        if out and out[-1].strip().lower() == p.strip().lower():
            continue
        out.append(p)
    return " ".join(out)


def coalesce(segments):
    """Merge consecutive same-speaker segments into one turn (Jamie-style):
    one speaker header, all their text joined."""
    blocks = []
    for s in sorted(segments, key=lambda x: x["start"]):
        if blocks and blocks[-1]["speaker"] == s["speaker"]:
            blocks[-1]["end"] = s["end"]
            blocks[-1]["text"] = (blocks[-1]["text"] + " " + s["text"]).strip()
        else:
            blocks.append(dict(s))
    return blocks


def max_db(wav):
    """Peak volume (dB) of a WAV via ffmpeg volumedetect, or None."""
    try:
        r = subprocess.run(
            ["/opt/homebrew/bin/ffmpeg", "-i", wav, "-af", "volumedetect", "-f", "null", "-"],
            capture_output=True, text=True, check=False,
        )
        import re
        m = re.search(r"max_volume:\s*(-?\d+\.?\d*) dB", r.stderr or "")
        return float(m.group(1)) if m else None
    except Exception:
        return None


def copy_to_downloads(meeting_dir):
    """Drop a copy of transcript.txt in ~/Downloads so it's ready to hand to Claude."""
    src = os.path.join(meeting_dir, "transcript.txt")
    if not os.path.exists(src):
        return None
    downloads = os.path.join(HOME, "Downloads")
    if not os.path.isdir(downloads):
        return None
    name = "upscale-talk meeting " + os.path.basename(os.path.normpath(meeting_dir)) + ".txt"
    dst = os.path.join(downloads, name)
    subprocess.run(["cp", src, dst], check=False)
    return dst


def to_mono(src, dst):
    """Downmix any WAV to 16 kHz mono (whisper-cli wants mono)."""
    subprocess.run(["/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-i", src,
                    "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-y", dst], check=True)
    return dst


def transcribe_words(wav, out_base):
    """whisper-cli (with -mc 0 loop self-heal) -> [{start,end,text}] (no speaker)."""
    data = _whisper_cli(wav, out_base)
    full = " ".join((s.get("text") or "") for s in data.get("transcription", []))
    if is_loop(full):
        data = _whisper_cli(wav, out_base, mc0=True)
    segs = []
    for s in data.get("transcription", []):
        text = (s.get("text") or "").strip()
        if not text or is_phantom(text):
            continue
        off = s.get("offsets", {})
        segs.append({"start": off.get("from", 0) / 1000.0,
                     "end": off.get("to", 0) / 1000.0, "text": text})
    return segs


def transcribe_me(meeting_dir, me_name):
    """Your mic channel -> segments all labelled `me_name` (mono-downmixed first)."""
    wav = os.path.join(meeting_dir, "me.wav")
    if not os.path.exists(wav):
        return []
    mono = to_mono(wav, os.path.join(meeting_dir, "me_mono.wav"))
    segs = transcribe_words(mono, os.path.join(meeting_dir, "me"))
    for s in segs:
        s["speaker"] = me_name
    return segs


def channels_independent(stereo_wav):
    """True if the two channels carry DIFFERENT audio (two mics), False if the
    source was mono duplicated across both channels. Tests the (ch0 - ch1) signal:
    identical channels cancel to silence; two real mics leave a strong difference."""
    import wave
    try:
        wf = wave.open(stereo_wav, "rb")
        nch = wf.getnchannels()
        wf.close()
    except Exception:
        nch = 1
    if nch < 2:
        return False   # mono recording — nothing to split
    diff = stereo_wav + ".diff.wav"
    subprocess.run(["/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-i", stereo_wav,
                    "-filter_complex", "[0:a]pan=mono|c0=c0-c1[d]", "-map", "[d]",
                    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", diff], check=False)
    peak = max_db(diff)
    try:
        os.remove(diff)
    except OSError:
        pass
    return peak is not None and peak > -70.0


def dual_mic_diarise(meeting_dir, stereo_wav):
    """Two mics, one clipped on each person (e.g. Rode Wireless MICRO). Transcribe
    the mono mix once, then assign each segment to whichever mic (channel) was
    louder in that window. Clean per-speaker labels, no ML — each person is
    loudest on their own lav even with a bit of cross-room bleed."""
    import wave
    import numpy as np
    ff = "/opt/homebrew/bin/ffmpeg"
    mic1 = os.path.join(meeting_dir, "mic1.wav")
    mic2 = os.path.join(meeting_dir, "mic2.wav")
    mix = os.path.join(meeting_dir, "mix.wav")
    for out, pan in ((mic1, "c0=c0"), (mic2, "c0=c1")):
        subprocess.run([ff, "-loglevel", "error", "-i", stereo_wav,
                        "-filter_complex", f"[0:a]pan=mono|{pan}[a]", "-map", "[a]",
                        "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", "-y", out], check=True)
    to_mono(stereo_wav, mix)

    segs = transcribe_words(mix, os.path.join(meeting_dir, "mix"))

    def load(w):
        wf = wave.open(w, "rb")
        a = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16).astype(np.float64)
        wf.close()
        return a

    a1, a2, sr = load(mic1), load(mic2), 16000

    def energy(a, s, e):
        seg = a[max(0, int(s * sr)):min(len(a), int(e * sr))]
        return float(np.sqrt(np.mean(seg * seg))) if len(seg) else 0.0

    out = []
    for s in segs:
        louder1 = energy(a1, s["start"], s["end"]) >= energy(a2, s["start"], s["end"])
        out.append({"start": s["start"], "end": s["end"],
                    "speaker": "Speaker 1" if louder1 else "Speaker 2", "text": s["text"]})
    return out


def diarise_wav(src_wav, work_dir, voices, model, min_spk, max_spk):
    """Run the video-transcriber (whisper + resemblyzer) on one WAV and return
    [{start,end,speaker,text}] with N-speaker labels, auto-named from the voice
    library. Used for the far side (remote) OR the mic (in-person, many voices)."""
    if not src_wav or not os.path.exists(src_wav):
        return []
    os.makedirs(work_dir, exist_ok=True)
    staged = os.path.join(work_dir, "audio.wav")
    subprocess.run(["cp", src_wav, staged], check=True)
    cmd = [
        sys.executable, DIARISE_SCRIPT, work_dir,
        "--output", work_dir,
        "--model", model,
        "--min-speakers", str(min_spk),
        "--max-speakers", str(max_spk),
        "--min-segment-duration", "2.0",
    ]
    if voices and os.path.isdir(voices) and os.listdir(voices):
        cmd += ["--references", voices]
    subprocess.run(cmd, check=True)
    js = os.path.join(work_dir, "audio.json")
    if not os.path.exists(js):
        return []
    data = json.load(open(js))
    segs = []
    for s in data.get("segments", []):
        text = (s.get("text") or "").strip()
        if not text or is_phantom(text):
            continue
        segs.append({
            "start": float(s.get("start", 0.0)),
            "end": float(s.get("end", 0.0)),
            "speaker": s.get("speaker", "Speaker ?"),
            "text": text,
        })
    return segs


def write_outputs(meeting_dir, segments):
    segments.sort(key=lambda s: s["start"])
    # transcript.json keeps the fine-grained segments (so naming can re-render).
    with open(os.path.join(meeting_dir, "transcript.json"), "w") as f:
        json.dump(segments, f, indent=2, ensure_ascii=False)
    # transcript.txt: minimal for LLMs — speaker name, then their text, per turn.
    # (Timestamps stay in transcript.json if you ever need to dive in.)
    lines = []
    for b in coalesce(segments):
        lines.append(b["speaker"])
        lines.append(collapse_repeats(b["text"]))
        lines.append("")
    with open(os.path.join(meeting_dir, "transcript.txt"), "w") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("meeting_dir")
    ap.add_argument("--me-name", default="Antoine")
    ap.add_argument("--voices", default=os.path.join(HOME, "upscale-talk/voices"))
    ap.add_argument("--model", default="small",
                    help="whisper model for the far-side channel (small/base/large-v3-turbo)")
    ap.add_argument("--min-speakers", type=int, default=1)
    ap.add_argument("--max-speakers", type=int, default=6)
    ap.add_argument("--no-dedupe", action="store_true",
                    help="keep mic-bleed echo of the far side (off = remove it)")
    args = ap.parse_args()

    md = args.meeting_dir
    if not os.path.isdir(md):
        sys.exit(f"meeting dir not found: {md}")
    if not os.path.exists(DIARISE_SCRIPT):
        sys.exit(f"diarisation script missing: {DIARISE_SCRIPT}")

    me_wav = os.path.join(md, "me.wav")
    them_wav = os.path.join(md, "them.wav")
    them_peak = max_db(them_wav) if os.path.exists(them_wav) else None
    has_far_side = them_peak is not None and them_peak >= SILENCE_MAX_DB

    dropped = 0
    if has_far_side:
        # Remote meeting: mic = you, far side (system audio) diarised separately.
        me = transcribe_me(md, args.me_name)
        them = diarise_wav(them_wav, os.path.join(md, "them"),
                           args.voices, args.model, args.min_speakers, args.max_speakers)
        if not args.no_dedupe:
            me, dropped = dedupe_mic_bleed(me, them)
        segments = me + them
    elif os.path.exists(me_wav) and channels_independent(me_wav):
        # In-person with two mics (one per person, e.g. Rode) → clean channel-split
        # diarisation: assign each turn to whichever mic was louder. No ML.
        print("dual-mic detected (2-channel input) — assigning speakers by loudest mic.")
        segments = dual_mic_diarise(md, me_wav)
    elif os.path.exists(me_wav):
        # In-person, single mic: everyone on one channel → diarise it (best-effort).
        print("no far-side audio, single mic — diarising the mic channel (best-effort).")
        me_mono = to_mono(me_wav, os.path.join(md, "me_mono.wav"))
        segments = diarise_wav(me_mono, os.path.join(md, "me_diar"),
                               args.voices, args.model, args.min_speakers, args.max_speakers)
    else:
        segments = []

    if not segments:
        sys.exit("no speech found in me.wav or them.wav")
    write_outputs(md, segments)
    dl = copy_to_downloads(md)
    if dropped:
        print(f"removed {dropped} mic-bleed echo segment(s) (far side leaking into your mic).")

    unnamed = sorted({s["speaker"] for s in segments if s["speaker"].lower().startswith("speaker")})
    print(f"transcript.txt written: {len(segments)} segments.")
    if dl:
        print(f"copied to Downloads: {dl}")
    if unnamed:
        print(f"UNNAMED far-side voices: {', '.join(unnamed)} "
              f"-> run name_speakers.py {md}")


if __name__ == "__main__":
    main()
