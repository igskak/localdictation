#!/usr/bin/env python3
"""Derive a leading-silence corpus from an existing benchmark corpus.

The TTS smoke corpus starts speaking at sample zero. A real recording does not:
it starts at the key press, and the first second or so is a breath, a pause,
the room. 0.6.6 shipped a language decision taken from the first 1.5 seconds
of the recording, and on a real press those seconds were mostly pause, came
back English with a confident margin, and a Russian dictation was inserted as
an English translation. Nothing in the smoke corpus could have caught that,
because nothing in it is silent at the start.

This writes a copy of every sample with room-level noise in front of it, at
several lengths, under <corpus>/leading-silence/ with its own corpus.json.
The noise is seeded, so the corpus is the same every time it is generated,
and it is noise rather than digital zero because a microphone never delivers
zero.

Mixed profiles on purpose: a single-language profile never asks the engine
which language it hears, so it cannot exercise the failure at all.

    ./Tools/make_leading_silence_corpus.py [path/to/Benchmark]

The source corpus lives in /Benchmark/ of the main checkout, which is
git-ignored; so is everything this writes.
"""
import json
import os
import random
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Longer than the 1.5 seconds 0.6.6 decided from, so at least one variant puts
# nothing but pause inside that window.
PAUSES = [0.5, 1.0, 1.5, 2.5]

# About -60 dBFS: a quiet room through a laptop microphone, not a studio.
NOISE_AMPLITUDE = 0.001

PROFILES = {
    "de": "de+en",
    "en": "ru+en+uk",
    "ru": "ru+en+uk",
    "uk": "ru+en+uk",
}

SAMPLE_RATE = 16000
WAVE_FORMAT_IEEE_FLOAT = 3


def read_float_wav(path):
    """Mono float32 samples from a WAVE file, as `say` writes them."""
    data = open(path, "rb").read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        sys.exit(f"{path}: not a RIFF/WAVE file")
    fmt = None
    samples = None
    offset = 12
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        size = struct.unpack("<I", data[offset + 4:offset + 8])[0]
        body = data[offset + 8:offset + 8 + size]
        if chunk_id == b"fmt ":
            fmt = struct.unpack("<HHIIHH", body[:16])
        elif chunk_id == b"data":
            samples = list(struct.unpack(f"<{size // 4}f", body[:size - size % 4]))
        offset += 8 + size + (size & 1)
    if fmt is None or samples is None:
        sys.exit(f"{path}: missing fmt or data chunk")
    audio_format, channels, rate, _, _, bits = fmt
    if (audio_format, channels, rate, bits) != (WAVE_FORMAT_IEEE_FLOAT, 1, SAMPLE_RATE, 32):
        sys.exit(f"{path}: expected mono float32 at {SAMPLE_RATE} Hz, found {fmt}")
    return samples


def write_float_wav(path, samples):
    body = struct.pack(f"<{len(samples)}f", *samples)
    fmt = struct.pack("<HHIIHH", WAVE_FORMAT_IEEE_FLOAT, 1, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 32)
    with open(path, "wb") as handle:
        handle.write(b"RIFF")
        handle.write(struct.pack("<I", 4 + 8 + len(fmt) + 8 + len(body)))
        handle.write(b"WAVE")
        handle.write(b"fmt " + struct.pack("<I", len(fmt)) + fmt)
        handle.write(b"data" + struct.pack("<I", len(body)) + body)


def main():
    source = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, "Benchmark")
    manifest_path = os.path.join(source, "corpus.json")
    if not os.path.exists(manifest_path):
        sys.exit(f"No corpus manifest at {manifest_path}")
    corpus = json.load(open(manifest_path, encoding="utf-8"))

    target = os.path.join(source, "leading-silence")
    os.makedirs(target, exist_ok=True)

    samples = []
    for sample in corpus["samples"]:
        speech = read_float_wav(os.path.join(source, sample["audio"]))
        stem = os.path.splitext(sample["audio"])[0]
        for pause in PAUSES:
            # Seeded per file and pause, so regenerating changes nothing.
            noise = random.Random(f"{sample['audio']}:{pause}")
            lead = [noise.gauss(0, NOISE_AMPLITUDE) for _ in range(int(pause * SAMPLE_RATE))]
            relative = f"{stem}-pause{pause:.1f}s.wav"
            os.makedirs(os.path.dirname(os.path.join(target, relative)), exist_ok=True)
            write_float_wav(os.path.join(target, relative), lead + speech)
            samples.append({
                "audio": relative,
                "reference": sample["reference"],
                "language": sample["language"],
                "profile": PROFILES.get(sample["language"], sample["language"]),
            })

    with open(os.path.join(target, "corpus.json"), "w", encoding="utf-8") as handle:
        json.dump({"name": "tts-leading-silence", "samples": samples}, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print(f"Wrote {len(samples)} samples to {target}")


if __name__ == "__main__":
    sys.exit(main())
