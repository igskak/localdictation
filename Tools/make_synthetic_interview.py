#!/usr/bin/env python3
"""Builds a long two-voice "interview" from macOS text-to-speech, with the
exact reference text and the true speaker turns.

It exists for the file-transcription engine benchmark (docs/FILE_TRANSCRIPTION_PLAN.md):
real-time factor, peak memory and lost intervals of a 60-minute or 3-hour
file need a recording of that length, and no consented one is kept in the
repository. Synthetic speech is cleaner than a real recording, so the word
error rate it yields is a floor, never the number to publish.

    python3 Tools/make_synthetic_interview.py --language de --minutes 60 --out DIR

Writes DIR/interview-<lang>-<minutes>.wav (16 kHz mono 16-bit), the same as
.m4a (AAC, what most people will drop in), and a reference JSON with one entry
per turn: speaker, start and end second, text.
"""
import argparse
import json
import os
import random
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 16_000

VOICES = {
    "de": ["Anna", "Eddy (German (Germany))"],
    "en": ["Samantha", "Eddy (English (US))"],
}

PARTS = {
    "de": {
        "openers": [
            "Ich glaube, dass", "Wir haben gesehen, dass", "Im Grunde ist es so, dass", "Meine Erfahrung ist, dass",
            "Man muss ehrlich sagen, dass", "Am Anfang dachten wir, dass", "Es hat sich gezeigt, dass",
            "Für mich war wichtig, dass", "Natürlich ist klar, dass", "Manchmal passiert es, dass",
        ],
        "subjects": [
            "die Zusammenarbeit im Team", "der Umzug nach Leipzig", "das neue Büro", "die Förderung durch die Stadt",
            "unser erstes Projekt", "die Arbeit mit den Schulen", "der Kontakt zu den Eltern", "die Finanzierung",
            "das Interview mit Frau Becker", "die Auswertung der Umfrage", "der Aufbau der Werkstatt",
            "die Beratung am Telefon", "der Austausch mit Herrn Krüger", "die Dokumentation der Ergebnisse",
        ],
        "verbs": [
            "viel besser funktioniert hat als erwartet", "uns vor große Fragen gestellt hat",
            "ungefähr drei Monate gedauert hat", "für alle Beteiligten wichtig geworden ist",
            "nicht ohne Schwierigkeiten verlaufen ist", "im Frühjahr noch ganz anders aussah",
            "mehr Zeit gebraucht hat, als wir geplant hatten", "am Ende überzeugend war",
            "zuerst kaum jemand verstanden hat", "inzwischen fast selbstverständlich ist",
        ],
        "tails": [
            "Das war ungefähr im Jahr {year}.", "Wir waren damals {n} Personen.", "Dafür haben wir etwa {n} Wochen gebraucht.",
            "Danach hat sich vieles verändert.", "Das hat mich wirklich überrascht.", "Darüber haben wir lange gesprochen.",
            "Die Kosten lagen bei rund {n} Euro.", "Ich erinnere mich genau an den {n}. Mai.", "Das sieht man heute noch.",
        ],
        "questions": [
            "Wie war das für Sie persönlich?", "Können Sie das etwas genauer erklären?", "Was hat Sie daran am meisten beschäftigt?",
            "Und wie haben die anderen darauf reagiert?", "Wann genau hat sich das geändert?", "Was würden Sie heute anders machen?",
            "Welche Rolle hat dabei die Familie gespielt?", "Wie ging es danach weiter?",
        ],
    },
    "en": {
        "openers": [
            "I think that", "What we saw was that", "Basically it comes down to the fact that", "In my experience",
            "To be honest,", "At the beginning we assumed that", "It turned out that", "For me it mattered that",
            "Of course it is clear that", "Sometimes it happens that",
        ],
        "subjects": [
            "the cooperation inside the team", "the move to Leeds", "the new office", "the funding from the council",
            "our first project", "the work with the schools", "the contact with the parents", "the budget",
            "the interview with Mrs Baker", "the analysis of the survey", "setting up the workshop",
            "the advice we gave on the phone", "the exchange with Mr Cooper", "the documentation of the results",
        ],
        "verbs": [
            "worked much better than expected", "raised some big questions for us", "took about three months",
            "became important for everybody involved", "did not go without difficulties", "looked completely different last spring",
            "needed more time than we had planned", "was convincing in the end", "hardly anyone understood at first",
            "is almost taken for granted by now",
        ],
        "tails": [
            "That was around the year {year}.", "There were {n} of us at the time.", "It took us about {n} weeks.",
            "A lot changed after that.", "That really surprised me.", "We talked about it for a long time.",
            "The costs were around {n} euro.", "I remember it exactly, it was the {n}th of May.", "You can still see it today.",
        ],
        "questions": [
            "How was that for you personally?", "Could you explain that a little more precisely?", "What occupied you most about it?",
            "And how did the others react?", "When exactly did that change?", "What would you do differently today?",
            "What role did the family play in this?", "How did it continue afterwards?",
        ],
    },
}


def sentence(rng, lang, kind):
    p = PARTS[lang]
    if kind == "question":
        return rng.choice(p["questions"])
    tail = rng.choice(p["tails"]).format(year=rng.randint(1998, 2024), n=rng.randint(3, 240))
    return f'{rng.choice(p["openers"])} {rng.choice(p["subjects"])} {rng.choice(p["verbs"])}. {tail}'


def speak(text, voice, rate, directory, index):
    path = os.path.join(directory, f"s{index}.wav")
    subprocess.run(
        ["say", "-v", voice, "-r", str(rate), "--file-format=WAVE", "--data-format=LEI16@16000", "-o", path, text],
        check=True,
    )
    with wave.open(path) as handle:
        assert handle.getframerate() == RATE and handle.getnchannels() == 1
        return np.frombuffer(handle.readframes(handle.getnframes()), dtype=np.int16)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", choices=sorted(VOICES), required=True)
    parser.add_argument("--minutes", type=float, required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--rate", type=int, default=175, help="words per minute for say")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    os.makedirs(args.out, exist_ok=True)
    target = int(args.minutes * 60 * RATE)
    voices = VOICES[args.language]
    pieces, turns, cursor, speaker, index = [], [], 0, 0, 0
    with tempfile.TemporaryDirectory() as scratch:
        while cursor < target:
            # The interviewer asks briefly; the guest answers at length, and
            # now and then talks for half a minute without a real pause.
            if speaker == 0:
                text = sentence(rng, args.language, "question")
            else:
                count = rng.choice([2, 3, 3, 4, 6, 10])
                text = " ".join(sentence(rng, args.language, "answer") for _ in range(count))
            gap_seconds = rng.choice([0.4, 0.6, 0.9, 1.2, 1.5, 2.0]) if rng.random() > 0.04 else rng.uniform(8, 15)
            audio = speak(text, voices[speaker], args.rate, scratch, index)
            gap = np.zeros(int(gap_seconds * RATE), dtype=np.int16)
            turns.append({
                "speaker": speaker + 1,
                "start": round(cursor / RATE, 3),
                "end": round((cursor + len(audio)) / RATE, 3),
                "text": text,
            })
            pieces.extend([audio, gap])
            cursor += len(audio) + len(gap)
            speaker = 1 - speaker
            index += 1
            if index % 50 == 0:
                print(f"{cursor / RATE / 60:.1f} min", file=sys.stderr)

    stem = os.path.join(args.out, f"interview-{args.language}-{int(args.minutes)}")
    samples = np.concatenate(pieces)
    with wave.open(stem + ".wav", "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(samples.tobytes())
    subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", stem + ".wav", stem + ".m4a"], check=True)
    with open(stem + ".reference.json", "w", encoding="utf-8") as handle:
        json.dump({"language": args.language, "seconds": round(len(samples) / RATE, 3), "turns": turns},
                  handle, ensure_ascii=False, indent=1)
    print(f"{stem}.wav {len(samples) / RATE / 60:.1f} min, {len(turns)} turns")


if __name__ == "__main__":
    main()
