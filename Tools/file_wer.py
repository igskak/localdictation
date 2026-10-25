#!/usr/bin/env python3
"""Word error rate of a file transcript against its reference.

    python3 Tools/file_wer.py REFERENCE.json TRANSCRIPT.txt

The reference is the JSON written by Tools/make_synthetic_interview.py. Both
sides are lower-cased and stripped of punctuation; digits stay digits, so a
number the model writes as a word counts as an error, which is the strict
reading and the one a person editing the transcript would also pay for.
"""
import json
import re
import sys


def words(text):
    return re.findall(r"[\w']+", text.lower(), flags=re.UNICODE)


def edit_distance(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, ref in enumerate(reference, 1):
        current = [i]
        for j, hyp in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ref != hyp)))
        previous = current
    return previous[-1]


def main():
    reference = json.load(open(sys.argv[1], encoding="utf-8"))
    hypothesis = words(open(sys.argv[2], encoding="utf-8").read())
    expected = words(" ".join(turn["text"] for turn in reference["turns"]))
    errors = edit_distance(expected, hypothesis)
    print(json.dumps({
        "referenceWords": len(expected),
        "hypothesisWords": len(hypothesis),
        "errors": errors,
        "wer": round(errors / len(expected), 4),
    }))


if __name__ == "__main__":
    main()
