#!/usr/bin/env python3
"""Appends missing English keys with their German value to Localizable.xcstrings
in the file's own one-line-per-entry layout, so the diff is only the new lines.

    python3 Tools/add_localizations.py strings.json

strings.json maps the English source string to its German translation. A key
that is already in the catalog is left alone.
"""
import json
import sys

CATALOG = "LocalDictation/Resources/Localizable.xcstrings"

new = json.load(open(sys.argv[1], encoding="utf-8"))
raw = open(CATALOG, encoding="utf-8").read()
existing = json.loads(raw)["strings"]
tail = '\n  },\n  "version": "1.0"\n}'
assert raw.rstrip().endswith(tail.strip()), "unexpected catalog tail"
head = raw[: raw.rindex(tail)]
lines = []
for key, german in new.items():
    if key in existing:
        continue
    entry = {"localizations": {"de": {"stringUnit": {"state": "translated", "value": german}}}}
    lines.append("    " + json.dumps(key, ensure_ascii=False) + ": " + json.dumps(entry, ensure_ascii=False, separators=(",", ":")))
if lines:
    head += ",\n" + ",\n".join(lines)
open(CATALOG, "w", encoding="utf-8").write(head + tail + "\n")
json.load(open(CATALOG, encoding="utf-8"))
print(f"added {len(lines)} of {len(new)}")
