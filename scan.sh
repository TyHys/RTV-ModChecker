#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/Mod-Checker/.venv/bin/activate"
cd "${SCRIPT_DIR}/Mod-Checker"
python3 -m mod_checker.cli scannremaining --all
python3 -m mod_checker.cli report