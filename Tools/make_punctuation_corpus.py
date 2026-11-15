#!/usr/bin/env python3
"""Speak the punctuation scripts with macOS TTS into a benchmark corpus.

    python3 Tools/make_punctuation_corpus.py [output-directory]

Default output: Benchmark/punctuation-tts/ in this checkout (git-ignored).

The macOS voices raise the pitch at a question mark, so this corpus answers
"does Whisper hear a question it is told about clearly" in a second-best way.
It is not a quality benchmark: synthesized speech is clean and evenly paced,
and Russian and Ukrainian yes/no questions are exactly where a real voice
differs most from a synthetic one. Read the scripts aloud with
Tools/record_punctuation_corpus.swift for the numbers that decide anything.

A blank line in a script becomes a 1.2 s pause, roughly how long people
pause between paragraphs when dictating; the reference keeps the blank line.
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "Tools", "punctuation_corpus_scripts.json")
DEFAULT_OUTPUT = os.path.join(ROOT, "Benchmark", "punctuation-tts")
CORPUS_NAME = "punctuation-tts"

VOICES = {"ru": "Milena", "uk": "Lesya", "de": "Anna", "en": "Samantha"}
PARAGRAPH_PAUSE_MS = 1200


def installed_voices():
    output = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return {line.split()[0] for line in output.splitlines() if line.strip()}


def spoken(text):
    return text.replace("\n\n", f" [[slnc {PARAGRAPH_PAUSE_MS}]] ").replace("\n", " ")


def main():
    output = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUTPUT
    manifest_path = os.path.join(output, "corpus.json")
    if os.path.exists(manifest_path):
        existing = json.load(open(manifest_path, encoding="utf-8"))
        if existing.get("name") != CORPUS_NAME:
            sys.exit(f"Refusing to overwrite corpus '{existing.get('name')}' at {manifest_path}")

    scripts = json.load(open(SCRIPTS, encoding="utf-8"))["languages"]
    available = installed_voices()
    samples = []
    for code, items in scripts.items():
        voice = VOICES[code]
        if voice not in available:
            print(f"skipping {code}: install the {voice} voice under System Settings > Accessibility > Spoken Content")
            continue
        directory = os.path.join(output, code)
        shutil.rmtree(directory, ignore_errors=True)
        os.makedirs(directory, exist_ok=True)
        for index, (kind, text) in enumerate(items, start=1):
            relative = f"{code}/{index:04d}.wav"
            subprocess.run(
                ["say", "-v", voice, "-o", os.path.join(output, relative),
                 "--data-format=LEF32@16000", "--file-format=WAVE", spoken(text)],
                check=True,
            )
            samples.append({"audio": relative, "reference": text, "language": code, "kind": kind})
        print(f"{code}: {len(items)} samples via {voice}")

    if not samples:
        sys.exit("No samples generated; no supported voices are installed.")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump({"name": CORPUS_NAME, "samples": samples}, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"\nWrote {manifest_path} with {len(samples)} samples.")


if __name__ == "__main__":
    sys.exit(main())
