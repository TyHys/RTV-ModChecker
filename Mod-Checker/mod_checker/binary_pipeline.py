from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BinaryAnalysisResult:
    extracted_text: str
    strategy: str
    extracted_count: int


PRINTABLE_RUN_RE = re.compile(rb"[\x20-\x7E]{6,}")


def extract_strings_for_analysis(path: Path, raw: bytes, max_strings: int = 2000) -> BinaryAnalysisResult:
    """
    Best-effort deserialization pipeline for binary resources.

    For high-volume automation this extracts printable string runs from binary data,
    which allows rule checks on script paths, loader calls, URLs, and suspicious tokens
    even when the underlying file is in engine-binary format.
    """
    strings: list[str] = []
    for match in PRINTABLE_RUN_RE.finditer(raw):
        token = match.group(0).decode("ascii", errors="ignore").strip()
        if not token:
            continue
        if _is_noise_token(token):
            continue
        strings.append(token)
        if len(strings) >= max_strings:
            break

    header = [f"# binary_string_extract: {path}", f"# extracted_count: {len(strings)}"]
    payload = "\n".join(header + strings)
    return BinaryAnalysisResult(extracted_text=payload, strategy="string_extract", extracted_count=len(strings))


def _is_noise_token(token: str) -> bool:
    # Drop mostly punctuation blobs to reduce false positives.
    alnum = sum(1 for ch in token if ch.isalnum())
    return alnum / max(len(token), 1) < 0.25

