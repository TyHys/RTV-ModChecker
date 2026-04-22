#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUMMARY_CSV="$ROOT_DIR/Mod-Checker/Analyses/Summary.csv"
DOC_PATH="$ROOT_DIR/Auxillary/Docs/Community-Safety-Checks-Overview.md"

if [[ ! -f "$SUMMARY_CSV" ]]; then
  echo "Missing summary file: $SUMMARY_CSV" >&2
  exit 1
fi

if [[ ! -f "$DOC_PATH" ]]; then
  echo "Missing doc file: $DOC_PATH" >&2
  exit 1
fi

python3 - "$SUMMARY_CSV" "$DOC_PATH" <<'PY'
import csv
import re
import sys
from collections import Counter
from pathlib import Path

summary_path = Path(sys.argv[1])
doc_path = Path(sys.argv[2])

with summary_path.open(newline="", encoding="utf-8") as handle:
    rows = list(csv.DictReader(handle))

counts = Counter((row.get("status") or "").strip().lower() for row in rows)
total = len(rows)

replacements = {
    "Total mods reviewed": total,
    "`clean`": counts.get("clean", 0),
    "`uncertain`": counts.get("uncertain", 0),
    "`suspicious`": counts.get("suspicious", 0),
    "`malicious`": counts.get("malicious", 0),
    "`error`": counts.get("error", 0),
}

text = doc_path.read_text(encoding="utf-8")

for label, value in replacements.items():
    pattern = rf"(-\s+{re.escape(label)}:\s+\*\*)\d+(\*\*)"
    new_text, changed = re.subn(pattern, rf"\g<1>{value}\2", text, count=1)
    if changed == 0:
        raise SystemExit(f"Could not find snapshot line for '{label}' in {doc_path}")
    text = new_text

doc_path.write_text(text, encoding="utf-8")

print(f"Updated snapshot counts from {summary_path}")
print(f"Total={total} clean={counts.get('clean',0)} uncertain={counts.get('uncertain',0)} "
      f"suspicious={counts.get('suspicious',0)} malicious={counts.get('malicious',0)} error={counts.get('error',0)}")
PY
