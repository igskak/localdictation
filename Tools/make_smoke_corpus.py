#!/usr/bin/env python3
"""Generate a TTS smoke corpus for the Phase 2 benchmark harness.

This verifies that the benchmark pipeline runs end to end -- corpus loading,
normalization, engine invocation, scoring, aggregation -- on all four MVP
languages, including German, without anyone having to record audio.

It is NOT a quality benchmark. Synthesized speech is unnaturally clean and
uniformly paced, so the error rates it produces say nothing about how either
engine behaves on a real microphone in a real room. Treat the numbers as
"the harness works", never as "the engine is this accurate".

Output goes to Benchmark/, which is git-ignored.
"""
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPUS = os.path.join(ROOT, "Benchmark")

# Sentences deliberately loaded with the categories the product promises to
# protect: amounts, dates, currency, names, and negation.
VOICES = {
    "de": "Anna",
    "en": "Samantha",
    "ru": "Milena",
    "uk": "Lesya",
}

SENTENCES = {
    "de": [
        "Bitte überweise 1450 Euro bis Freitag an Müller GmbH.",
        "Der Termin am dritten März wurde nicht bestätigt.",
        "Die Rechnung ist noch offen, Betrag 89 Euro.",
        "Wir liefern nicht vor dem fünfzehnten April.",
        "Kontostand: zweitausendfünfhundert Euro.",
        "Frau Schneider hat den Vertrag abgelehnt.",
    ],
    "en": [
        "Please transfer 1450 euro to Miller by Friday.",
        "The meeting on March third was not confirmed.",
        "The invoice is still open, amount 89 euro.",
        "We will not ship before April fifteenth.",
        "Balance: two thousand five hundred euro.",
        "Ms Schneider rejected the contract.",
    ],
    "ru": [
        "Переведи 1450 евро Мюллеру до пятницы.",
        "Встреча третьего марта не подтверждена.",
        "Счёт всё ещё открыт, сумма 89 евро.",
        "Мы не отгрузим раньше пятнадцатого апреля.",
        "Остаток: две тысячи пятьсот евро.",
        "Госпожа Шнайдер отклонила договор.",
    ],
    "uk": [
        "Переказати 1450 євро Мюллеру до п'ятниці.",
        "Зустріч третього березня не підтверджена.",
        "Рахунок усе ще відкритий, сума 89 євро.",
        "Ми не відвантажимо раніше п'ятнадцятого квітня.",
        "Залишок: дві тисячі п'ятсот євро.",
        "Пані Шнайдер відхилила договір.",
    ],
}


def installed_voices():
    output = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
    return {line.split()[0] for line in output.splitlines() if line.strip()}


def main():
    manifest_path = os.path.join(CORPUS, "corpus.json")
    if os.path.exists(manifest_path):
        existing = json.load(open(manifest_path, encoding="utf-8"))
        if existing.get("name") != "tts-smoke":
            sys.exit(
                f"Refusing to overwrite a non-smoke corpus at {manifest_path}\n"
                f"  (found corpus '{existing.get('name')}'). Move it aside first."
            )

    available = installed_voices()
    missing = {code: voice for code, voice in VOICES.items() if voice not in available}
    if missing:
        print("Missing system voices; install them under System Settings →")
        print("Accessibility → Spoken Content → System Voice → Manage Voices:")
        for code, voice in missing.items():
            print(f"  {code}: {voice}")

    samples = []
    for code, sentences in SENTENCES.items():
        voice = VOICES[code]
        if voice in missing:
            print(f"skipping {code}: no {voice} voice")
            continue

        directory = os.path.join(CORPUS, code)
        shutil.rmtree(directory, ignore_errors=True)
        os.makedirs(directory, exist_ok=True)

        for index, sentence in enumerate(sentences, start=1):
            relative = f"{code}/{index:04d}.wav"
            subprocess.run(
                ["say", "-v", voice, "-o", os.path.join(CORPUS, relative),
                 "--data-format=LEF32@16000", "--file-format=WAVE", sentence],
                check=True,
            )
            samples.append({
                "audio": relative,
                "reference": sentence,
                "language": code,
            })
        print(f"{code}: {len(sentences)} samples via {voice}")

    if not samples:
        sys.exit("No samples generated; no supported voices are installed.")

    os.makedirs(CORPUS, exist_ok=True)
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump({"name": "tts-smoke", "samples": samples}, handle,
                  ensure_ascii=False, indent=2)
        handle.write("\n")

    print(f"\nWrote {manifest_path} with {len(samples)} samples.")
    print("This checks the harness, not engine quality. See docs/PHASE_2_BENCHMARK.md.")


if __name__ == "__main__":
    sys.exit(main())
