from __future__ import annotations

import re
from pathlib import Path

from mod_checker.models import Finding


SCRIPT_EXTENSIONS = {".gd", ".txt", ".cfg", ".json", ".ini", ".xml", ".tres", ".res", ".cs"}
BLOCKED_EXTENSIONS = {
    ".exe",
    ".dll",
    ".so",
    ".dylib",
    ".bat",
    ".cmd",
    ".ps1",
    ".psm1",
    ".sh",
    ".msi",
    ".vbs",
    ".js",
    ".jse",
    ".wsf",
    ".lnk",
    ".scr",
    ".com",
}

PATTERN_RULES = [
    ("EXEC-001", "critical", "Process execution pattern", re.compile(r"\bOS\.(execute|create_process)\b")),
    (
        "CMD-001",
        "critical",
        "cmd.exe execution indicator",
        re.compile(r"\bcmd(\.exe)?\s+/(c|k)\b|\bstart\s+/b\s+cmd(\.exe)?\b", re.IGNORECASE),
    ),
    ("NET-001", "high", "Network request indicator", re.compile(r"\b(HTTPRequest|StreamPeerTCP|WebSocketClient|UDPServer|TCPServer)\b")),
    ("PS-001", "critical", "PowerShell execution indicator", re.compile(r"powershell(\.exe)?|Add-MpPreference|-ExclusionPath", re.IGNORECASE)),
    ("IOC-001", "critical", "Known attacker domain indicator", re.compile(r"roadtovostok\.store", re.IGNORECASE)),
    ("OBF-001", "critical", "Obfuscation indicator", re.compile(r"(base64|Marshalls\.base64_to_raw|_0x[0-9a-f]+|xor)", re.IGNORECASE)),
    (
        "OBF-002",
        "high",
        "Encoded byte-array payload indicator",
        re.compile(r"\[(?:\s*\d{1,3}\s*,){20,}\s*\d{1,3}\s*\]"),
    ),
    (
        "PATH-001",
        "high",
        "Suspicious absolute/system path usage",
        re.compile(
            r"(%APPDATA%|%TEMP%|C:/ProgramData|/etc/|CurrentVersion\\\\Run|HKEY_(LOCAL_MACHINE|CURRENT_USER)|\\\\Startup\\\\|/Startup/)",
            re.IGNORECASE,
        ),
    ),
]
SHELL_OPEN_RE = re.compile(r"\bOS\.shell_open\s*\((.+)\)")
PACK_LOAD_RE = re.compile(r"load_resource_pack\s*\(")


def evaluate_file_content(path: Path, content: str) -> list[Finding]:
    findings: list[Finding] = []
    lines = content.splitlines()
    for rule_id, severity, title, regex in PATTERN_RULES:
        for match in regex.finditer(content):
            line_no = content.count("\n", 0, match.start()) + 1
            if rule_id == "OBF-001" and is_benign_obf_context(path, lines, line_no):
                continue
            if rule_id == "CMD-001" and is_benign_cmd_context(path):
                continue
            if rule_id == "PATH-001" and is_comment_line(lines, line_no):
                continue
            excerpt = build_excerpt(content, match.start(), match.end())
            findings.append(
                Finding(
                    rule_id=rule_id,
                    severity=severity,
                    title=title,
                    evidence=f"Matched `{match.group(0)}` at line {line_no} (pattern: {regex.pattern})",
                    recommendation="Manual review required before approval.",
                    file_path=str(path),
                    code_excerpt=excerpt,
                )
            )
            # Keep per-file output readable while still preserving concrete references.
            if len([f for f in findings if f.rule_id == rule_id and f.file_path == str(path)]) >= 3:
                break
    findings.extend(evaluate_shell_open_usage(path, content))
    findings.extend(evaluate_pack_loading_usage(path, content))
    return findings


def build_excerpt(content: str, start: int, end: int, context_lines: int = 2) -> str:
    lines = content.splitlines()
    if not lines:
        return ""

    start_line = content.count("\n", 0, start)
    end_line = content.count("\n", 0, end)
    first = max(0, start_line - context_lines)
    last = min(len(lines) - 1, end_line + context_lines)

    numbered: list[str] = []
    for idx in range(first, last + 1):
        numbered.append(f"{idx + 1}: {lines[idx]}")
    return "\n".join(numbered)


def evaluate_shell_open_usage(path: Path, content: str) -> list[Finding]:
    findings: list[Finding] = []
    for match in SHELL_OPEN_RE.finditer(content):
        line_no = content.count("\n", 0, match.start()) + 1
        arg_text = match.group(1).strip()
        severity = "medium"
        title = "OS.shell_open usage"
        recommendation = "Validate the destination opened by shell_open."
        arg_lower = arg_text.lower()

        if "roadtovostok.store" in arg_lower:
            severity = "critical"
            title = "shell_open known attacker domain"
            recommendation = "Reject. Domain is associated with known malware campaigns."
        elif "projectsettings.globalize_path" in arg_lower:
            severity = "low"
            title = "shell_open local path usage"
            recommendation = "Likely benign local folder launch; verify destination path intent."
        elif "http" in arg_lower:
            if "modworkshop.net/" in arg_lower:
                severity = "low"
                title = "shell_open trusted modworkshop link"
                recommendation = "Likely benign dependency/help link."
            else:
                severity = "high"
                title = "shell_open external URL"
                recommendation = "Review URL carefully for phishing or payload-hosting risk."
        elif "cmd" in arg_lower or "powershell" in arg_lower:
            severity = "high"
            title = "shell_open command invocation string"
            recommendation = "Review command string carefully for script execution behavior."
        elif "://" not in arg_lower:
            # Most shell_open usage in Godot mods opens local files/folders.
            severity = "low"
            title = "shell_open local path usage"
            recommendation = "Likely benign local path launch; verify destination path intent."

        findings.append(
            Finding(
                rule_id="EXEC-002",
                severity=severity,
                title=title,
                evidence=f"Matched `OS.shell_open(...)` at line {line_no}",
                recommendation=recommendation,
                file_path=str(path),
                code_excerpt=build_excerpt(content, match.start(), match.end()),
            )
        )
    return findings


def evaluate_pack_loading_usage(path: Path, content: str) -> list[Finding]:
    findings: list[Finding] = []
    is_known_loader_context = path.name.lower() in {"modloader.gd", "loader.gd"} and (
        "MOD_DIR" in content or "ZIPReader" in content or "_load_all_mods" in content
    )

    for match in PACK_LOAD_RE.finditer(content):
        line_no = content.count("\n", 0, match.start()) + 1
        severity = "critical"
        title = "Runtime resource pack loading"
        recommendation = "Reject unless this behavior is explicitly expected and reviewed."
        if is_known_loader_context:
            severity = "low"
            title = "Runtime resource pack loading in mod-loader context"
            recommendation = "Expected for loader mods; manually confirm it only mounts local mod packs."
        findings.append(
            Finding(
                rule_id="PACK-001",
                severity=severity,
                title=title,
                evidence=f"Matched `load_resource_pack(` at line {line_no}",
                recommendation=recommendation,
                file_path=str(path),
                code_excerpt=build_excerpt(content, match.start(), match.end()),
            )
        )
    return findings


def is_benign_obf_context(path: Path, lines: list[str], line_no: int) -> bool:
    """
    Avoid OBF false positives on serialized asset blobs.
    Example: Font/texture PackedByteArray data inside .tres resources.
    """
    suffix = path.suffix.lower()
    lowered_name = path.name.lower()
    # Dependency lockfiles frequently contain package names like "base64-js".
    if lowered_name in {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "pnpm-lock.yml"}:
        return True
    binary_asset_suffixes = {".ctex", ".res", ".scn", ".import", ".mesh", ".anim", ".png", ".jpg", ".jpeg", ".webp", ".glb"}
    if suffix in binary_asset_suffixes:
        return True
    if suffix not in {".tres"}:
        return False
    if line_no < 1 or line_no > len(lines):
        return False
    line = lines[line_no - 1]
    return "PackedByteArray(" in line or line.strip().startswith("data = PackedByteArray(")


def is_benign_cmd_context(path: Path) -> bool:
    suffix = path.suffix.lower()
    binary_asset_suffixes = {".ctex", ".res", ".scn", ".import", ".mesh", ".anim", ".png", ".jpg", ".jpeg", ".webp", ".glb"}
    return suffix in binary_asset_suffixes


def is_comment_line(lines: list[str], line_no: int) -> bool:
    if line_no < 1 or line_no > len(lines):
        return False
    stripped = lines[line_no - 1].lstrip()
    return stripped.startswith("#") or stripped.startswith("//")

