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
DIAR_DIR = os.path.join(HOME, "upscale-talk/models/diarisation")   # sherpa-onnx models
DIAR_THRESHOLD = 0.8   # cosine cluster threshold for auto speaker-count (tunable)


SILENCE_MAX_DB = -70.0     # a channel below this peak is a dead/silent capture
FAR_SIDE_MEAN_DB = -48.0   # far side counts as "present" only with real sustained
                           # speech (mean), not a few blips — a failed tap sits ~-56

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


def _volumedetect(wav, field):
    try:
        r = subprocess.run(
            ["/opt/homebrew/bin/ffmpeg", "-i", wav, "-af", "volumedetect", "-f", "null", "-"],
            capture_output=True, text=True, check=False,
        )
        m = re.search(rf"{field}:\s*(-?\d+\.?\d*) dB", r.stderr or "")
        return float(m.group(1)) if m else None
    except Exception:
        return None


def max_db(wav):
    """Peak volume (dB) of a WAV, or None."""
    return _volumedetect(wav, "max_volume")


def mean_db(wav):
    """Mean volume (dB) — sustained energy / speech presence. A few loud blips
    can't inflate it the way they inflate the peak, so this is what decides
    whether a channel actually carries a conversation."""
    return _volumedetect(wav, "mean_volume")


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


def _merge_tiny_speakers(turns, min_frac=0.04, min_secs=8.0):
    """Fold spurious tiny clusters into the temporally-nearest real speaker, so
    single-mic noise can't invent extra people. Real speakers keep every turn;
    a genuine third person (with real talk-time) is preserved."""
    from collections import defaultdict
    if not turns:
        return turns
    total = sum(e - s for s, e, _ in turns)
    talk = defaultdict(float)
    for s, e, spk in turns:
        talk[spk] += e - s
    keep = {spk for spk, d in talk.items() if d >= min_secs and d >= min_frac * total}
    if not keep or len(keep) == len(talk):
        return turns

    def nearest_keep(t0, t1):
        best, bd = None, 1e9
        for s, e, spk in turns:
            if spk not in keep:
                continue
            d = 0.0 if not (e < t0 or s > t1) else min(abs(s - t1), abs(e - t0))
            if d < bd:
                bd, best = d, spk
        return best if best is not None else sorted(keep)[0]

    return [(s, e, spk if spk in keep else nearest_keep(s, e)) for s, e, spk in turns]


def sherpa_turns(mono_wav, num_speakers=-1, threshold=DIAR_THRESHOLD):
    """sherpa-onnx offline diarisation (pyannote segmentation + WeSpeaker
    embeddings) -> cleaned [(start, end, speaker_int)]. Local, offline, no token."""
    import wave
    import numpy as np
    import sherpa_onnx
    wf = wave.open(mono_wav, "rb")
    ch = wf.getnchannels()
    a = np.frombuffer(wf.readframes(wf.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    wf.close()
    if ch == 2:
        a = a.reshape(-1, 2).mean(axis=1)
    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=os.path.join(DIAR_DIR, "segmentation.onnx"))),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=os.path.join(DIAR_DIR, "embedding.onnx")),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=num_speakers, threshold=threshold),
        min_duration_on=0.3, min_duration_off=0.5,
    )
    res = sherpa_onnx.OfflineSpeakerDiarization(cfg).process(a).sort_by_start_time()
    return _merge_tiny_speakers([(r.start, r.end, r.speaker) for r in res])


def _speaker_at(turns, t):
    for s, e, spk in turns:
        if s <= t <= e:
            return spk
    if not turns:
        return 0
    return min(turns, key=lambda x: min(abs(x[0] - t), abs(x[1] - t)))[2]


def diarise_wav(src_wav, work_dir, num_speakers=-1):
    """Diarise one WAV: sherpa-onnx for speaker turns + whisper-cli for the words,
    intersected by timestamp. Returns [{start,end,speaker,text}] with 1-indexed
    'Speaker N' labels (stable by first appearance). Used for the far side
    (remote) or the mic (in-person, single shared mic)."""
    if not src_wav or not os.path.exists(src_wav):
        return []
    os.makedirs(work_dir, exist_ok=True)
    mono = to_mono(src_wav, os.path.join(work_dir, "audio.wav"))
    turns = sherpa_turns(mono, num_speakers=num_speakers)
    words = transcribe_words(mono, os.path.join(work_dir, "audio"))
    remap, out = {}, []
    for w in words:
        spk = _speaker_at(turns, (w["start"] + w["end"]) / 2.0)
        if spk not in remap:
            remap[spk] = f"Speaker {len(remap) + 1}"
        out.append({"start": w["start"], "end": w["end"],
                    "speaker": remap[spk], "text": w["text"]})
    return out


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
    ap.add_argument("--speakers", type=int, default=2,
                    help="people sharing the mic for an in-person meeting (default 2; "
                         "set 3+ for a bigger room). The far side of a remote call auto-detects.")
    ap.add_argument("--no-dedupe", action="store_true",
                    help="keep mic-bleed echo of the far side (off = remove it)")
    args = ap.parse_args()

    md = args.meeting_dir
    if not os.path.isdir(md):
        sys.exit(f"meeting dir not found: {md}")
    if not os.path.exists(os.path.join(DIAR_DIR, "segmentation.onnx")):
        sys.exit(f"diarisation models missing in {DIAR_DIR} — run helpers/setup-meeting-mode.sh")

    me_wav = os.path.join(md, "me.wav")
    them_wav = os.path.join(md, "them.wav")
    # "Far side present" needs sustained speech (mean), not loud blips — a failed
    # system-audio tap is near-silent on average (~-56 dB) but can peak high, which
    # used to fool this into the remote path. If the tap failed, fall through to
    # diarising the mic, which on speakers/in-person holds the whole conversation.
    them_mean = mean_db(them_wav) if os.path.exists(them_wav) else None
    has_far_side = them_mean is not None and them_mean >= FAR_SIDE_MEAN_DB

    dropped = 0
    if has_far_side:
        # Remote meeting: mic = you, far side (system audio) diarised separately.
        me = transcribe_me(md, args.me_name)
        them = diarise_wav(them_wav, os.path.join(md, "them"), num_speakers=-1)  # far side: auto
        if not args.no_dedupe:
            me, dropped = dedupe_mic_bleed(me, them)
        segments = me + them
    elif os.path.exists(me_wav) and channels_independent(me_wav):
        # In-person with two mics (one per person, e.g. Rode) → clean channel-split
        # diarisation: assign each turn to whichever mic was louder. No ML.
        print("dual-mic detected (2-channel input) — assigning speakers by loudest mic.")
        segments = dual_mic_diarise(md, me_wav)
    elif os.path.exists(me_wav):
        # In-person, single shared mic → sherpa-onnx diarisation, count = --speakers
        # (auto-count on one mic is unreliable, so we fix it; default 2).
        print(f"no far-side audio, single mic — diarising ({args.speakers} speakers).")
        segments = diarise_wav(me_wav, os.path.join(md, "me_diar"), num_speakers=args.speakers)
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
