from __future__ import annotations

import hashlib
import re
from pathlib import Path


SAFE_CHARS_PATTERN = re.compile(r"[^A-Za-z0-9._-]+")
DASH_PATTERN = re.compile(r"-{2,}")


def sanitize_name(raw: str) -> str:
    name = raw.strip().replace(" ", "-")
    name = SAFE_CHARS_PATTERN.sub("-", name)
    name = DASH_PATTERN.sub("-", name).strip("-")
    return name or "unknown-mod-name"


def analysis_folder_name(mod_id: str, mod_name: str, mod_version: str) -> str:
    return f"{sanitize_name(mod_id)}-{sanitize_name(mod_name)}-{sanitize_name(mod_version)}"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

