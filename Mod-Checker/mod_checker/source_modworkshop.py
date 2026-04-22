from __future__ import annotations

import json
import re
import time
from datetime import UTC, datetime, timedelta
from html import unescape
from urllib.parse import urljoin
from urllib.parse import urlparse
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from mod_checker.models import ModEntry
from mod_checker.utils import sanitize_name


TIME_AGO_RE = re.compile(r"(\d+)\s+(minute|minutes|hour|hours|day|days)\s+ago", re.IGNORECASE)
MOD_LINK_RE = re.compile(r"^/mod/(\d+)")
MOD_COUNT_RE = re.compile(r"Mods\s*(\d+)\s*Mods", re.IGNORECASE)


class ModWorkshopSource:
    def __init__(self, base_url: str, timeout_seconds: int = 25) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_seconds = timeout_seconds
        self.user_agent = "rtv-mod-checker/0.1"
        parsed = urlparse(self.base_url)
        self.site_root = f"{parsed.scheme}://{parsed.netloc}"
        self.request_delay_seconds = 0.2

    def fetch_newest(self, limit: int, only_mod_id: str | None = None, all_pages: bool = False) -> list[ModEntry]:
        entries = list(self.iter_newest(limit=limit, only_mod_id=only_mod_id, all_pages=all_pages))
        entries.sort(key=lambda item: (item.uploaded_at, int(item.mod_id)), reverse=True)
        return entries[:limit]

    def fetch_total_mod_count(self) -> int | None:
        try:
            homepage = self._fetch_text(self.base_url)
        except Exception:  # noqa: BLE001
            return None
        match = MOD_COUNT_RE.search(strip_tags(homepage))
        if not match:
            return None
        try:
            value = int(match.group(1))
        except ValueError:
            return None
        return value if value > 0 else None

    def iter_newest(self, limit: int, only_mod_id: str | None = None, all_pages: bool = False):
        entries: list[ModEntry] = []
        seen_ids: set[str] = set()
        page = 1
        max_pages = 200 if all_pages else 1

        while page <= max_pages and len(entries) < limit:
            page_url = self.base_url if page == 1 else f"{self.base_url}?page={page}"
            homepage = self._fetch_text(page_url)
            page_mods = extract_mod_links(homepage)
            if not page_mods:
                break

            added_this_page = 0
            for href, text in page_mods:
                match = MOD_LINK_RE.match(href.strip())
                if not match:
                    continue

                mod_id = match.group(1)
                if mod_id in seen_ids:
                    continue
                if only_mod_id and mod_id != only_mod_id:
                    continue

                mod_url = urljoin(self.site_root + "/", href.lstrip("/"))
                card_text = text.strip()
                mod_name = sanitize_name(card_text) or f"mod-{mod_id}"
                uploaded_at = self._infer_uploaded_time(homepage, mod_id) or datetime.now(UTC)

                detail = self._fetch_detail(mod_id, mod_url)
                detail_uploaded_at = parse_api_datetime(detail.get("published_at"))
                entry = ModEntry(
                    mod_id=mod_id,
                    mod_name=detail.get("name", mod_name),
                    mod_version=detail.get("version", "unknown-version"),
                    mod_url=mod_url,
                    uploaded_at=detail_uploaded_at or uploaded_at,
                    download_url=detail.get("download_url"),
                    author_name=detail.get("author_name"),
                    author_id=detail.get("author_id"),
                )
                entries.append(entry)
                yield entry
                seen_ids.add(mod_id)
                added_this_page += 1
                if len(entries) >= limit:
                    break
            if added_this_page == 0:
                break
            page += 1

    def _fetch_detail(self, mod_id: str, mod_url: str) -> dict[str, str | None]:
        api_detail = self._fetch_mod_api_detail(mod_id)
        if api_detail:
            return api_detail

        try:
            html = self._fetch_text(mod_url)
        except Exception:  # noqa: BLE001
            return {"name": "unknown-mod", "version": "unknown-version", "download_url": None}

        mod_name = extract_first_tag_text(html, "h1") or "unknown-mod"
        version = normalize_version(self._extract_version_text(html)) or "unknown-version"
        download_url = None
        for href, _ in extract_links(html):
            if "download" in href or href.endswith((".zip", ".vmz", ".pck")):
                download_url = urljoin(mod_url + "/", href.lstrip("/"))
                break
        return {
            "name": mod_name,
            "version": version,
            "download_url": download_url,
            "published_at": None,
            "author_name": None,
            "author_id": None,
        }

    def _fetch_mod_api_detail(self, mod_id: str) -> dict[str, str | None] | None:
        try:
            mod_payload = self._fetch_json(f"{self.site_root}/api/mods/{mod_id}")
        except Exception:  # noqa: BLE001
            return None

        name = (mod_payload.get("name") or "").strip() or "unknown-mod"
        version = normalize_version(str(mod_payload.get("version") or "")) or "unknown-version"
        published_at = mod_payload.get("published_at")
        user_payload = mod_payload.get("user") if isinstance(mod_payload.get("user"), dict) else {}
        author_name = (user_payload.get("name") or "").strip() or None
        author_id = str(user_payload.get("id")) if user_payload.get("id") is not None else None

        files_payload = {}
        try:
            files_payload = self._fetch_json(f"{self.site_root}/api/mods/{mod_id}/files")
        except Exception:  # noqa: BLE001
            files_payload = {}
        download_url = pick_download_url(files_payload)
        if not download_url:
            download_url = self._best_effort_download_from_html(mod_id)

        return {
            "name": name,
            "version": version,
            "download_url": download_url,
            "published_at": published_at,
            "author_name": author_name,
            "author_id": author_id,
        }

    def _fetch_text(self, url: str) -> str:
        request = Request(url=url, headers={"User-Agent": self.user_agent})
        return self._open_with_retry(request).decode("utf-8", errors="ignore")

    def _fetch_json(self, url: str) -> dict:
        request = Request(
            url=url,
            headers={
                "User-Agent": self.user_agent,
                "Accept": "application/json",
            },
        )
        return json.loads(self._open_with_retry(request).decode("utf-8", errors="ignore"))

    def _open_with_retry(self, request: Request) -> bytes:
        delay = 1.0
        for attempt in range(6):
            if self.request_delay_seconds > 0:
                time.sleep(self.request_delay_seconds)
            try:
                with urlopen(request, timeout=self.timeout_seconds) as response:  # noqa: S310
                    return response.read()
            except HTTPError as exc:
                if exc.code == 429 and attempt < 5:
                    retry_after = exc.headers.get("Retry-After")
                    if retry_after and retry_after.isdigit():
                        delay = float(retry_after)
                    time.sleep(delay)
                    delay = min(delay * 2, 30.0)
                    continue
                raise
        raise RuntimeError("Failed to fetch after retry attempts")

    def _best_effort_download_from_html(self, mod_id: str) -> str | None:
        try:
            html = self._fetch_text(f"{self.site_root}/mod/{mod_id}")
        except Exception:  # noqa: BLE001
            return None
        match = re.search(r"https://storage\.modworkshop\.net/mods/files/[^\s\"'<>]+", html, re.IGNORECASE)
        return match.group(0) if match else None

    @staticmethod
    def _extract_version_text(html: str) -> str | None:
        for candidate in strip_tags(html).splitlines():
            lowered = candidate.lower()
            if "version" in lowered:
                value = candidate.split(":")[-1].strip()
                if value.lower() == "version":
                    match = re.search(r"\bv(?:ersion)?\.?\s*([0-9][a-z0-9.\-_]*)", candidate, flags=re.IGNORECASE)
                    value = match.group(1) if match else ""
                if value and len(value) < 64:
                    return value
        return None

    @staticmethod
    def _infer_uploaded_time(html: str, mod_id: str) -> datetime | None:
        match_window = re.search(rf"/mod/{re.escape(mod_id)}(.{{0,300}})", html, flags=re.IGNORECASE | re.DOTALL)
        combined = match_window.group(1) if match_window else html[:2000]
        match = TIME_AGO_RE.search(combined)
        if not match:
            return None
        amount = int(match.group(1))
        unit = match.group(2).lower()
        delta_seconds = amount * 60
        if unit.startswith("hour"):
            delta_seconds = amount * 3600
        elif unit.startswith("day"):
            delta_seconds = amount * 86400
        return datetime.now(UTC) - timedelta(seconds=delta_seconds)


def extract_links(html: str) -> list[tuple[str, str]]:
    pattern = re.compile(r"<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", re.IGNORECASE | re.DOTALL)
    items: list[tuple[str, str]] = []
    for match in pattern.finditer(html):
        href = unescape(match.group(1).strip())
        text = strip_tags(match.group(2)).strip()
        items.append((href, text))
    return items


def extract_mod_links(html: str) -> list[tuple[str, str]]:
    return [(href, text) for href, text in extract_links(html) if MOD_LINK_RE.match(href)]


def extract_first_tag_text(html: str, tag: str) -> str | None:
    pattern = re.compile(rf"<{tag}[^>]*>(.*?)</{tag}>", re.IGNORECASE | re.DOTALL)
    match = pattern.search(html)
    if not match:
        return None
    return strip_tags(match.group(1)).strip()


def strip_tags(value: str) -> str:
    text = re.sub(r"<[^>]+>", "\n", value)
    text = unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{2,}", "\n", text)
    return text.strip()


def normalize_version(value: str | None) -> str | None:
    if not value:
        return None
    cleaned = value.strip().replace(" ", "-")
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "", cleaned)
    cleaned = cleaned.strip("-.")
    if not cleaned:
        return None
    return cleaned[:64]


def parse_api_datetime(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed.astimezone(UTC)


def pick_download_url(files_payload: dict) -> str | None:
    rows = files_payload.get("data")
    if not isinstance(rows, list):
        return None

    # Prefer most recently updated file with vmz/zip/pck extension.
    def sort_key(item: dict) -> tuple:
        updated = item.get("updated_at") or ""
        created = item.get("created_at") or ""
        return (updated, created, item.get("id", 0))

    sorted_rows = sorted([row for row in rows if isinstance(row, dict)], key=sort_key, reverse=True)
    for row in sorted_rows:
        direct = row.get("download_url")
        if isinstance(direct, str) and direct.strip():
            return direct.strip()
        file_name = row.get("file")
        if isinstance(file_name, str) and file_name.lower().endswith((".zip", ".vmz", ".pck")):
            return f"https://storage.modworkshop.net/mods/files/{file_name}"
    return None

