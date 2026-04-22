from __future__ import annotations

import csv
import json
import shutil
from datetime import UTC, datetime
from pathlib import Path

from mod_checker.models import ModEntry, ScanResult
from mod_checker.scanner import ENGINE_VERSION
from mod_checker.utils import analysis_folder_name


class AnalysisStorage:
    def __init__(self, analyses_root: Path) -> None:
        self.analyses_root = analyses_root
        self.analyses_root.mkdir(parents=True, exist_ok=True)
        self.index_path = self.analyses_root / "Summary.csv"

    def folder_name(self, mod: ModEntry) -> str:
        return analysis_folder_name(mod.mod_id, mod.mod_name, mod.mod_version)

    def exists(self, mod: ModEntry) -> bool:
        return (self.analyses_root / self.folder_name(mod)).exists()

    def write_analysis(self, mod: ModEntry, result: ScanResult, extracted_dir: Path | None) -> Path:
        out_dir = self.analyses_root / self.folder_name(mod)
        out_dir.mkdir(parents=True, exist_ok=True)
        artifacts_dir = out_dir / "artifacts"
        artifacts_dir.mkdir(parents=True, exist_ok=True)

        metadata = {
            "modId": mod.mod_id,
            "modName": mod.mod_name,
            "modVersion": mod.mod_version,
            "authorName": mod.author_name,
            "authorId": mod.author_id,
            "modUrl": mod.mod_url,
            "source": mod.source,
            "uploadedAt": mod.uploaded_at.isoformat(),
            "checkedAt": datetime.now(UTC).isoformat(),
            "archiveHashSha256": result.archive_sha256,
            "analysisFolder": out_dir.name,
            "downloadUrl": mod.download_url,
        }
        (out_dir / "metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        (out_dir / "scan-results.json").write_text(
            json.dumps(result.to_json_dict(engine_version=ENGINE_VERSION), indent=2),
            encoding="utf-8",
        )
        (out_dir / "scan-summary.md").write_text(self._summary_markdown(mod, result), encoding="utf-8")

        if extracted_dir and extracted_dir.exists():
            copied_dir = artifacts_dir / "extracted"
            if copied_dir.exists():
                shutil.rmtree(copied_dir)
            shutil.copytree(extracted_dir, copied_dir)

        self._append_index(mod, result, out_dir)
        return out_dir

    def _append_index(self, mod: ModEntry, result: ScanResult, out_dir: Path) -> None:
        counts = result.finding_counts()
        row = {
            "checkedAt": datetime.now(UTC).isoformat(),
            "analysisFolder": out_dir.name,
            "modId": mod.mod_id,
            "modName": mod.mod_name,
            "modVersion": mod.mod_version,
            "authorName": mod.author_name or "",
            "authorId": mod.author_id or "",
            "modUrl": mod.mod_url,
            "status": result.status,
            "riskScore": result.risk_score,
            "findingsLow": counts.get("low", 0),
            "findingsMedium": counts.get("medium", 0),
            "findingsHigh": counts.get("high", 0),
            "findingsCritical": counts.get("critical", 0),
            "uncertainReasons": " | ".join(result.uncertain_reasons),
        }
        fieldnames = self._index_fieldnames()
        existing_rows = self._read_index_rows(fieldnames)
        deduped_rows = [
            item
            for item in existing_rows
            if not (
                item.get("analysisFolder") == out_dir.name
                or (item.get("modId") == mod.mod_id and item.get("modVersion") == mod.mod_version)
            )
        ]
        deduped_rows.append(row)

        with self.index_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(deduped_rows)

    def _read_index_rows(self, fieldnames: list[str]) -> list[dict[str, str]]:
        if not self.index_path.exists() or self.index_path.stat().st_size == 0:
            return []
        with self.index_path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            rows: list[dict[str, str]] = []
            for item in reader:
                # Normalize both legacy and report schema keys to current schema.
                source = item
                if "analysis_folder" in item:
                    source = {
                        "checkedAt": item.get("checked_at", ""),
                        "analysisFolder": item.get("analysis_folder", ""),
                        "modId": item.get("mod_id", ""),
                        "modName": item.get("mod_name", ""),
                        "modVersion": item.get("mod_version", ""),
                        "authorName": "",
                        "authorId": "",
                        "modUrl": item.get("mod_url", ""),
                        "status": item.get("status", ""),
                        "riskScore": item.get("risk_score", ""),
                        "findingsLow": item.get("findings_low", ""),
                        "findingsMedium": item.get("findings_medium", ""),
                        "findingsHigh": item.get("findings_high", ""),
                        "findingsCritical": item.get("findings_critical", ""),
                        "uncertainReasons": item.get("uncertain_reasons", ""),
                    }
                rows.append({key: str(source.get(key, "")) for key in fieldnames})
            return rows

    @staticmethod
    def _index_fieldnames() -> list[str]:
        return [
            "checkedAt",
            "analysisFolder",
            "modId",
            "modName",
            "modVersion",
            "authorName",
            "authorId",
            "modUrl",
            "status",
            "riskScore",
            "findingsLow",
            "findingsMedium",
            "findingsHigh",
            "findingsCritical",
            "uncertainReasons",
        ]

    @staticmethod
    def _summary_markdown(mod: ModEntry, result: ScanResult) -> str:
        lines = [
            f"# Scan Summary: {mod.mod_name}",
            "",
            f"- Mod ID: `{mod.mod_id}`",
            f"- Mod URL: `{mod.mod_url}`",
            f"- Mod Version: `{mod.mod_version}`",
            f"- Status: `{result.status}`",
            f"- Risk Score: `{result.risk_score}`",
            "",
            "## Findings",
        ]
        if result.uncertain_reasons:
            lines.insert(7, f"- Uncertain Reasons: `{'; '.join(result.uncertain_reasons)}`")
        if not result.findings:
            lines.append("- No findings detected.")
        else:
            for item in result.findings:
                location = f" ({item.file_path})" if item.file_path else ""
                lines.append(f"- [{item.severity}] {item.rule_id}: {item.title}{location}")
                lines.append(f"  - Evidence: {item.evidence}")
                if item.code_excerpt:
                    lines.append("  - Code excerpt:")
                    lines.append("")
                    lines.append("```text")
                    lines.append(item.code_excerpt)
                    lines.append("```")
                lines.append(f"  - Recommendation: {item.recommendation}")
        if result.errors:
            lines.extend(["", "## Errors", *[f"- {err}" for err in result.errors]])
        return "\n".join(lines) + "\n"

