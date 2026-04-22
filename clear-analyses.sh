#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANALYSES_DIR="${SCRIPT_DIR}/Mod-Checker/Analyses"

if [[ ! -d "${ANALYSES_DIR}" ]]; then
  echo "Analyses directory not found: ${ANALYSES_DIR}"
  exit 1
fi

rm -rf "${ANALYSES_DIR:?}"/*
mkdir -p "${ANALYSES_DIR}"

echo "Cleared analyses: ${ANALYSES_DIR}"
