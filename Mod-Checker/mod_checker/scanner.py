from __future__ import annotations

import json
import re
import tempfile
import zipfile
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse
from urllib.request import Request, urlopen

try:
    import rarfile
except ModuleNotFoundError:  # pragma: no cover - optional dependency at runtime
    rarfile = None

from mod_checker.binary_pipeline import extract_strings_for_analysis
from mod_checker.models import Finding, ModEntry, ScanResult
from mod_checker.rules import BLOCKED_EXTENSIONS, SCRIPT_EXTENSIONS, evaluate_file_content
from mod_checker.utils import sha256_file


ENGINE_VERSION = "0.1.0"
BATCH_SUSPICIOUS_RE = re.compile(
    r"(powershell|cmd\.exe|wscript|cscript|mshta|rundll32|reg\s+add|"
    r"bitsadmin|certutil|curl|wget|http://|https://|-enc(odedcommand)?)",
    re.IGNORECASE,
)
GITHUB_REPO_RE = re.compile(r"https?://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)")
REPOSITORY_SECTION_LINK_RE = re.compile(
    r"Repository URL(?:\s|<[^>]+>)*?<a[^>]+href=[\"']([^\"']+)[\"']",
    re.IGNORECASE | re.DOTALL,
)


class Scanner:
    def __init__(self, timeout_seconds: int = 30) -> None:
        self.timeout_seconds = timeout_seconds
        self.user_agent = "rtv-mod-checker/0.1"
        self.deserializable_extensions = {".res", ".scn", ".ctex", ".import", ".mesh", ".anim"}

    def scan(self, mod: ModEntry) -> tuple[ScanResult, Path | None]:
        if not mod.download_url:
            result = ScanResult(status="error", risk_score=100, errors=["No downloadable file URL found."])
            return result, None

        with tempfile.TemporaryDirectory(prefix="rtv-mod-checker-") as temp_dir:
            temp_path = Path(temp_dir)
            archive_path = temp_path / "mod-archive.bin"
            try:
                self._download_file(mod.download_url, archive_path)
            except Exception as exc:  # noqa: BLE001
                return ScanResult(status="error", risk_score=100, errors=[f"Download failed: {exc}"]), None

            archive_sha256 = sha256_file(archive_path)
            source_name = "downloaded_file"
            if mod.download_url:
                source_name = Path(urlparse(mod.download_url).path).name or source_name
            findings = self._scan_archive(archive_path, source_name)
            findings.extend(self._scan_linked_github_repo_if_needed(mod, findings, temp_path))
            status, risk_score, uncertain_reasons = score_from_findings(findings)
            result = ScanResult(
                status=status,
                risk_score=risk_score,
                findings=findings,
                archive_sha256=archive_sha256,
                uncertain_reasons=uncertain_reasons,
            )
            return result, None

    def _download_file(self, download_url: str, target_path: Path) -> None:
        request = Request(url=download_url, headers={"User-Agent": self.user_agent})
        with target_path.open("wb") as handle:
            with urlopen(request, timeout=self.timeout_seconds) as response:  # noqa: S310
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)

    def _download_text(self, url: str) -> str:
        request = Request(url=url, headers={"User-Agent": self.user_agent})
        with urlopen(request, timeout=self.timeout_seconds) as response:  # noqa: S310
            payload = response.read()
        return payload.decode("utf-8", errors="ignore")

    def _scan_archive(self, archive_path: Path, source_name: str) -> list[Finding]:
        findings: list[Finding] = []
        deserialized_files = 0

        if zipfile.is_zipfile(archive_path):
            with zipfile.ZipFile(archive_path, "r") as archive:
                for info in archive.infolist():
                    normalized = info.filename.replace("\\", "/")
                    if normalized.startswith("/") or "../" in normalized:
                        findings.append(
                            Finding(
                                rule_id="ARCHIVE-TRAVERSAL-001",
                                severity="critical",
                                title="Path traversal candidate in archive entry",
                                evidence=normalized,
                                recommendation="Reject this mod version.",
                                file_path=normalized,
                            )
                        )
                        continue
                    if info.is_dir():
                        continue

                    member_findings, member_deserialized = self._scan_archive_member(
                        normalized,
                        lambda info=info: archive.read(info),
                    )
                    findings.extend(member_findings)
                    deserialized_files += member_deserialized
        elif self._is_rar_archive(archive_path, source_name):
            if rarfile is None:
                findings.append(
                    Finding(
                        rule_id="ARCHIVE-001",
                        severity="low",
                        title="Archive format not yet supported by scanner",
                        evidence="RAR archive detected but optional 'rarfile' dependency is not installed.",
                        recommendation="Install rarfile support to scan .rar packages automatically.",
                    )
                )
            else:
                try:
                    with rarfile.RarFile(archive_path, "r") as archive:
                        for info in archive.infolist():
                            normalized = info.filename.replace("\\", "/")
                            if normalized.startswith("/") or "../" in normalized:
                                findings.append(
                                    Finding(
                                        rule_id="ARCHIVE-TRAVERSAL-001",
                                        severity="critical",
                                        title="Path traversal candidate in archive entry",
                                        evidence=normalized,
                                        recommendation="Reject this mod version.",
                                        file_path=normalized,
                                    )
                                )
                                continue
                            if info.isdir():
                                continue

                            member_findings, member_deserialized = self._scan_archive_member(
                                normalized,
                                lambda info=info: archive.read(info),
                            )
                            findings.extend(member_findings)
                            deserialized_files += member_deserialized
                except Exception as exc:  # noqa: BLE001
                    findings.append(
                        Finding(
                            rule_id="ARCHIVE-001",
                            severity="low",
                            title="Archive format not yet supported by scanner",
                            evidence=f"RAR archive could not be parsed: {exc}",
                            recommendation="Perform manual review or request a zip-format release.",
                        )
                    )
        else:
            raw = archive_path.read_bytes()
            source_suffix = Path(source_name).suffix.lower()
            if source_suffix in BLOCKED_EXTENSIONS:
                if source_suffix == ".bat" and is_likely_text(raw):
                    findings.append(classify_batch_script_finding(source_name, raw.decode("utf-8", errors="ignore")))
                else:
                    rule_id, severity, title, recommendation = classify_blocked_extension(source_suffix)
                    findings.append(
                        Finding(
                            rule_id=rule_id,
                            severity=severity,
                            title=title,
                            evidence=f"Downloaded package is blocked executable type {source_suffix}",
                            recommendation=recommendation,
                            file_path=source_name,
                        )
                    )
            elif is_likely_text(raw):
                content = raw.decode("utf-8", errors="ignore")
                findings.extend(evaluate_file_content(Path(source_name), content))
            else:
                findings.append(
                    Finding(
                        rule_id="ARCHIVE-001",
                        severity="low",
                        title="Archive format not yet supported by scanner",
                        evidence="Only zip-compatible archives are currently scanned.",
                        recommendation="Scanner could not fully inspect this package; perform manual review or request zip-format release.",
                    )
                )

        if deserialized_files > 0:
            findings.append(
                Finding(
                    rule_id="DESER-001",
                    severity="low",
                    title="Binary deserialization pipeline executed",
                    evidence=f"Processed {deserialized_files} binary resource file(s) with automated string extraction.",
                    recommendation="For flagged results, validate specific resources in Godot editor.",
                )
            )

        return dedupe_findings(findings)

    def _scan_linked_github_repo_if_needed(self, mod: ModEntry, current_findings: list[Finding], temp_path: Path) -> list[Finding]:
        source_suffix = Path(urlparse(mod.download_url or "").path).suffix.lower()
        has_native_binary = any(item.rule_id == "ARCHIVE-NATIVE-001" for item in current_findings)
        if source_suffix != ".exe" and not has_native_binary:
            return []
        if not mod.mod_url:
            return []

        repo_url = self._extract_github_repo_url(mod.mod_url)
        if not repo_url:
            return []

        owner_repo = self._parse_github_owner_repo(repo_url)
        if owner_repo is None:
            return []
        owner, repo = owner_repo

        try:
            default_branch = self._fetch_github_default_branch(owner, repo)
            repo_archive_url = f"https://codeload.github.com/{owner}/{repo}/zip/refs/heads/{default_branch}"
            repo_archive_path = temp_path / "linked-github-repo.zip"
            self._download_file(repo_archive_url, repo_archive_path)
            repo_findings = self._scan_archive(repo_archive_path, f"{repo}.zip")
        except Exception as exc:  # noqa: BLE001
            return [
                Finding(
                    rule_id="GITHUB-REPO-001",
                    severity="low",
                    title="Linked GitHub repo fetch failed",
                    evidence=f"Tried fetching linked repo {repo_url} but failed: {exc}",
                    recommendation="Review linked repository manually.",
                )
            ]

        scoped_findings: list[Finding] = []
        for finding in repo_findings:
            prefixed_path = f"github:{owner}/{repo}/{finding.file_path}" if finding.file_path else None
            scoped_findings.append(
                Finding(
                    rule_id=finding.rule_id,
                    severity=finding.severity,
                    title=finding.title,
                    evidence=finding.evidence,
                    recommendation=finding.recommendation,
                    file_path=prefixed_path,
                    code_excerpt=finding.code_excerpt,
                )
            )
        scoped_findings.append(
            Finding(
                rule_id="GITHUB-REPO-001",
                severity="low",
                title="Linked GitHub repo was scanned",
                evidence=f"Scanned linked repository source: {repo_url} (branch: {default_branch}).",
                recommendation="Use repo findings as additional context for trust decisions.",
            )
        )
        return scoped_findings

    def _scan_archive_member(self, normalized: str, read_bytes: Callable[[], bytes]) -> tuple[list[Finding], int]:
        findings: list[Finding] = []
        deserialized_files = 0
        suffix = Path(normalized).suffix.lower()
        file_bytes: bytes | None = None
        if suffix in BLOCKED_EXTENSIONS or suffix in SCRIPT_EXTENSIONS or suffix in self.deserializable_extensions:
            try:
                file_bytes = read_bytes()
            except Exception:  # noqa: BLE001
                return findings, deserialized_files

        if suffix in BLOCKED_EXTENSIONS:
            if suffix == ".bat" and file_bytes is not None:
                findings.append(classify_batch_script_finding(normalized, file_bytes.decode("utf-8", errors="ignore")))
            else:
                rule_id, severity, title, recommendation = classify_blocked_extension(suffix)
                findings.append(
                    Finding(
                        rule_id=rule_id,
                        severity=severity,
                        title=title,
                        evidence=f"Archive contains blocked extension {suffix}",
                        recommendation=recommendation,
                        file_path=normalized,
                    )
                )

        if suffix not in SCRIPT_EXTENSIONS and suffix not in self.deserializable_extensions:
            return findings, deserialized_files
        try:
            raw = file_bytes if file_bytes is not None else b""
            if is_likely_text(raw):
                content = raw.decode("utf-8", errors="ignore")
                findings.extend(evaluate_file_content(Path(normalized), content))
            elif suffix in self.deserializable_extensions:
                deserialized = extract_strings_for_analysis(Path(normalized), raw)
                if deserialized.extracted_count == 0:
                    return findings, deserialized_files
                findings.extend(evaluate_file_content(Path(normalized), deserialized.extracted_text))
                deserialized_files += 1
            else:
                return findings, deserialized_files
        except OSError:
            return findings, deserialized_files
        if Path(normalized).name == "mod.txt" and is_likely_text(raw):
            content = raw.decode("utf-8", errors="ignore")
            findings.extend(self._scan_manifest(Path(normalized), content))
        if Path(normalized).name == "override.cfg" and is_likely_text(raw):
            findings.append(classify_override_cfg_finding(normalized, raw.decode("utf-8", errors="ignore")))
        return findings, deserialized_files

    @staticmethod
    def _is_rar_archive(archive_path: Path, source_name: str) -> bool:
        if source_name.lower().endswith(".rar"):
            return True
        if rarfile is None:
            return False
        try:
            return rarfile.is_rarfile(str(archive_path))
        except Exception:  # noqa: BLE001
            return False

    def _extract_github_repo_url(self, mod_url: str) -> str | None:
        try:
            page_html = self._download_text(mod_url)
        except Exception:  # noqa: BLE001
            return None

        # Prefer explicit "Repository URL" field from the mod page to avoid
        # matching unrelated footer/site GitHub links.
        repo_section_match = REPOSITORY_SECTION_LINK_RE.search(page_html)
        if repo_section_match:
            candidate = repo_section_match.group(1).strip()
            owner_repo = self._parse_github_owner_repo(candidate)
            if owner_repo and not self._is_irrelevant_github_repo(owner_repo):
                owner, repo = owner_repo
                return f"https://github.com/{owner}/{repo}"

        match = GITHUB_REPO_RE.search(page_html)
        if not match:
            return None
        owner = match.group(1)
        repo = match.group(2).removesuffix(".git")
        if self._is_irrelevant_github_repo((owner, repo)):
            return None
        return f"https://github.com/{owner}/{repo}"

    @staticmethod
    def _parse_github_owner_repo(repo_url: str) -> tuple[str, str] | None:
        parsed = urlparse(repo_url)
        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) < 2:
            return None
        return parts[0], parts[1].removesuffix(".git")

    def _fetch_github_default_branch(self, owner: str, repo: str) -> str:
        api_url = f"https://api.github.com/repos/{owner}/{repo}"
        payload = self._download_text(api_url)
        data = json.loads(payload)
        branch = data.get("default_branch")
        if isinstance(branch, str) and branch:
            return branch
        return "main"

    @staticmethod
    def _is_irrelevant_github_repo(owner_repo: tuple[str, str]) -> bool:
        owner, repo = owner_repo
        return (owner.lower(), repo.lower()) in {
            ("modworkshop", "site"),
        }

    @staticmethod
    def _scan_manifest(path: Path, content: str) -> list[Finding]:
        findings: list[Finding] = []
        lowered = content.lower()
        if "modworkshop=" in lowered and "modworkshop.net" not in lowered:
            findings.append(
                Finding(
                    rule_id="MANIFEST-URL-001",
                    severity="low",
                    title="Manifest update metadata does not match expected modworkshop format",
                    evidence="Found [updates] modworkshop value that does not include modworkshop.net.",
                    recommendation="Ask maintainer to fix metadata formatting in a future update.",
                    file_path=str(path),
                )
            )
        if ".." in content:
            findings.append(
                Finding(
                    rule_id="MANIFEST-PATH-001",
                    severity="critical",
                    title="Potential traversal path in manifest",
                    evidence="Found '..' in mod.txt autoload/update values.",
                    recommendation="Reject or require corrected manifest.",
                    file_path=str(path),
                )
            )
        return findings


def dedupe_findings(findings: list[Finding]) -> list[Finding]:
    seen: set[str] = set()
    unique: list[Finding] = []
    for finding in findings:
        key = json.dumps(
            [
                finding.rule_id,
                finding.severity,
                finding.title,
                finding.evidence,
                finding.file_path,
            ],
            sort_keys=True,
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(finding)
    return unique


def score_from_findings(findings: list[Finding]) -> tuple[str, int, list[str]]:
    weights = {"low": 5, "medium": 15, "high": 35, "critical": 60}
    score = sum(weights.get(item.severity, 0) for item in findings)
    if _is_uncertain_native_provenance_case(findings):
        reasons = [
            "Native executable was provided, but linked GitHub source did not show direct malicious indicators.",
            "Binary provenance cannot be cryptographically verified from available artifacts.",
        ]
        return "uncertain", 35, reasons
    if any(item.severity == "critical" for item in findings):
        return "malicious", min(score, 100), []
    if any(item.severity == "high" for item in findings):
        return "suspicious", min(score, 95), []
    if any(item.severity == "medium" for item in findings):
        return "suspicious", min(score, 70), []

    uncertain_findings = [
        item for item in findings if item.rule_id in {"ARCHIVE-001", "GITHUB-REPO-001"} and item.severity == "low"
    ]
    if uncertain_findings:
        reasons = [f"{item.rule_id}: {item.evidence}" for item in uncertain_findings]
        return "uncertain", max(min(score, 30), 5), reasons

    # Low-severity findings are informational and should not mark a mod suspicious.
    return "clean", 0, []


def _is_uncertain_native_provenance_case(findings: list[Finding]) -> bool:
    has_native = any(item.rule_id == "ARCHIVE-NATIVE-001" and item.severity == "high" for item in findings)
    if not has_native:
        return False
    has_github_context = any(item.rule_id == "GITHUB-REPO-001" for item in findings)
    if not has_github_context:
        return False
    has_other_high_or_critical = any(
        item.rule_id != "ARCHIVE-NATIVE-001" and item.severity in {"high", "critical"} for item in findings
    )
    return not has_other_high_or_critical


def is_likely_text(data: bytes) -> bool:
    if not data:
        return False
    if b"\x00" in data:
        return False
    sample = data[:4096]
    printable = sum(1 for b in sample if b in b"\t\n\r" or 32 <= b <= 126)
    ratio = printable / len(sample)
    return ratio >= 0.85


def classify_blocked_extension(suffix: str) -> tuple[str, str, str, str]:
    # Script launchers are higher-risk than native helper binaries in legitimate native mods.
    if suffix in {".ps1", ".psm1", ".cmd", ".msi", ".vbs", ".jse", ".wsf", ".lnk", ".scr", ".com"}:
        return (
            "ARCHIVE-EXEC-001",
            "critical",
            "High-risk executable script payload included",
            "Reject unless maintainer provides strong justification and source transparency.",
        )
    if suffix == ".js":
        return (
            "ARCHIVE-EXEC-003",
            "high",
            "JavaScript payload included",
            "Review script contents for launcher/downloader behavior before approval.",
        )
    if suffix == ".bat":
        return (
            "ARCHIVE-EXEC-002",
            "medium",
            "Batch launcher script included",
            "Review script commands; allow only if behavior is transparent and expected.",
        )
    if suffix in {".exe", ".dll", ".so", ".dylib"}:
        return (
            "ARCHIVE-NATIVE-001",
            "high",
            "Native binary component included",
            "Manual trust review required (publisher reputation, source availability, and behavior checks).",
        )
    return (
        "ARCHIVE-EXEC-001",
        "high",
        "Executable or script payload included",
        "Manual security review required.",
    )


def classify_batch_script_finding(path: str, content: str) -> Finding:
    stripped = content.strip()
    if not stripped:
        return Finding(
            rule_id="ARCHIVE-EXEC-002",
            severity="low",
            title="Local batch helper script included",
            evidence="Archive contains empty or placeholder .bat script without executable commands.",
            recommendation="Likely packaging/dev helper; keep under review but do not mark suspicious by itself.",
            file_path=path,
        )
    if BATCH_SUSPICIOUS_RE.search(content):
        return Finding(
            rule_id="ARCHIVE-EXEC-002",
            severity="medium",
            title="Batch launcher script included",
            evidence="Archive contains .bat script with command/network execution indicators.",
            recommendation="Review script commands; allow only if behavior is transparent and expected.",
            file_path=path,
        )
    return Finding(
        rule_id="ARCHIVE-EXEC-002",
        severity="low",
        title="Local batch helper script included",
        evidence="Archive contains .bat script without obvious network/downloader indicators.",
        recommendation="Likely packaging/dev helper; keep under review but do not mark suspicious by itself.",
        file_path=path,
    )


def classify_override_cfg_finding(path: str, content: str) -> Finding:
    lowered = content.lower()
    suspicious_markers = ("http://", "https://", "..", "cmd", "powershell", "os.execute", "load_resource_pack(")
    if any(marker in lowered for marker in suspicious_markers):
        return Finding(
            rule_id="OVERRIDE-001",
            severity="high",
            title="override.cfg included in archive",
            evidence="override.cfg contains non-trivial entries requiring manual trust review.",
            recommendation="Manual review required for autoload injection risk.",
            file_path=path,
        )
    return Finding(
        rule_id="OVERRIDE-001",
        severity="low",
        title="override.cfg included in archive",
        evidence="override.cfg appears to contain local autoload configuration only.",
        recommendation="Common for framework/loader mods; keep under routine review.",
        file_path=path,
    )

