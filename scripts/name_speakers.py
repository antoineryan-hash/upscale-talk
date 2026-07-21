#!/usr/bin/env python3
"""
name_speakers.py <meeting_dir>

Post-meeting speaker identification. For each far-side voice the diariser left as
"Speaker N", it plays a short snippet of that voice and asks who it was. Your
answer relabels every turn by that voice in transcript.txt / transcript.json,
and saves a reference clip to ~/upscale-talk/voices/<Name>.wav so the SAME voice
is auto-named in future meetings (no re-prompting).

Your own mic channel is already labelled, so you're only asked about the others.

Interactive: run in a Terminal. Enter a name, or press Enter to skip a voice.
"""
import argparse
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
FFMPEG = "/opt/homebrew/bin/ffmpeg"


def mmss(seconds):
    s = int(round(seconds))
    return f"{s // 60:02d}:{s % 60:02d}"


def collapse_repeats(text):
    """Drop consecutive duplicate sentences (Whisper repetition-loop tails)."""
    import re
    out = []
    for p in re.split(r"(?<=[.!?])\s+", text):
        if out and out[-1].strip().lower() == p.strip().lower():
            continue
        out.append(p)
    return " ".join(out)


def coalesce(segments):
    """Merge consecutive same-speaker segments into one turn (Jamie-style)."""
    blocks = []
    for s in sorted(segments, key=lambda x: x["start"]):
        if blocks and blocks[-1]["speaker"] == s["speaker"]:
            blocks[-1]["end"] = s["end"]
            blocks[-1]["text"] = (blocks[-1]["text"] + " " + s["text"]).strip()
        else:
            blocks.append(dict(s))
    return blocks


def write_txt(meeting_dir, segments):
    lines = []
    for b in coalesce(segments):
        lines.append(b["speaker"])
        lines.append(collapse_repeats(b["text"]))
        lines.append("")
    open(os.path.join(meeting_dir, "transcript.txt"), "w").write("\n".join(lines))
    # Keep the Downloads copy current after speakers are named.
    downloads = os.path.join(HOME, "Downloads")
    if os.path.isdir(downloads):
        name = "upscale-talk meeting " + os.path.basename(os.path.normpath(meeting_dir)) + ".txt"
        subprocess.run(["cp", os.path.join(meeting_dir, "transcript.txt"),
                        os.path.join(downloads, name)], check=False)


def longest_segment(segments, speaker):
    segs = [s for s in segments if s["speaker"] == speaker]
    return max(segs, key=lambda s: s["end"] - s["start"]) if segs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("meeting_dir")
    ap.add_argument("--voices", default=os.path.join(HOME, "upscale-talk/voices"))
    ap.add_argument("--no-play", action="store_true", help="don't afplay snippets")
    args = ap.parse_args()

    md = args.meeting_dir
    tj = os.path.join(md, "transcript.json")
    them_wav = os.path.join(md, "them.wav")
    if not os.path.exists(tj):
        sys.exit(f"no transcript.json in {md} — run meeting_transcribe.py first")
    segments = json.load(open(tj))
    os.makedirs(args.voices, exist_ok=True)

    unnamed = sorted({s["speaker"] for s in segments
                      if s["speaker"].lower().startswith("speaker")})
    if not unnamed:
        print("No unnamed far-side voices — nothing to do.")
        return

    print(f"{len(unnamed)} far-side voice(s) to identify. Enter a name, or blank to skip.\n")
    for spk in unnamed:
        rep = longest_segment(segments, spk)
        if rep is None:
            continue
        dur = min(8.0, max(1.5, rep["end"] - rep["start"]))
        snippet = os.path.join(md, f"_snippet_{spk.replace(' ', '_')}.wav")
        if os.path.exists(them_wav):
            subprocess.run(
                [FFMPEG, "-loglevel", "error", "-ss", str(rep["start"]), "-t", str(dur),
                 "-i", them_wav, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
                 "-y", snippet],
                check=False,
            )
        print(f"--- {spk}  (says: \"{rep['text'][:80]}\")")
        if os.path.exists(snippet) and not args.no_play:
            subprocess.run(["afplay", snippet], check=False)
        try:
            name = input(f"Who is {spk}? ").strip()
        except EOFError:
            name = ""
        if not name:
            print(f"  skipped {spk}\n")
            if os.path.exists(snippet):
                os.remove(snippet)
            continue
        # Relabel every turn by this voice.
        for s in segments:
            if s["speaker"] == spk:
                s["speaker"] = name
        # Save a reference clip so this voice auto-names next time.
        if os.path.exists(snippet):
            ref = os.path.join(args.voices, f"{name}.wav")
            os.replace(snippet, ref)
            print(f"  labelled as {name}; saved voice reference -> {ref}\n")
        else:
            print(f"  labelled as {name} (no snippet to save)\n")

    json.dump(segments, open(tj, "w"), indent=2, ensure_ascii=False)
    write_txt(md, segments)
    still = sorted({s["speaker"] for s in segments if s["speaker"].lower().startswith("speaker")})
    print("Updated transcript.txt / transcript.json.")
    if still:
        print(f"Still unnamed (skipped): {', '.join(still)}")


if __name__ == "__main__":
    main()
