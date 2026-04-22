from __future__ import annotations

import csv
import json
from pathlib import Path


def build_csv_report(analyses_root: Path, output_csv: Path) -> int:
    rows: list[dict[str, str | int]] = []
    for entry in sorted(analyses_root.iterdir()):
        if not entry.is_dir():
            continue
        metadata_path = entry / "metadata.json"
        results_path = entry / "scan-results.json"
        if not metadata_path.exists() or not results_path.exists():
            continue
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
            results = json.loads(results_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            continue

        findings = results.get("findings", [])
        top_rules = ",".join(sorted({str(f.get("ruleId", "")) for f in findings if f.get("ruleId")}))
        rows.append(
            {
                "analysis_folder": entry.name,
                "mod_id": metadata.get("modId", ""),
                "mod_name": metadata.get("modName", ""),
                "mod_version": metadata.get("modVersion", ""),
                "mod_url": metadata.get("modUrl", ""),
                "uploaded_at": metadata.get("uploadedAt", ""),
                "checked_at": metadata.get("checkedAt", ""),
                "status": results.get("status", ""),
                "risk_score": results.get("riskScore", 0),
                "findings_total": len(findings),
                "findings_low": (results.get("findingCounts") or {}).get("low", 0),
                "findings_medium": (results.get("findingCounts") or {}).get("medium", 0),
                "findings_high": (results.get("findingCounts") or {}).get("high", 0),
                "findings_critical": (results.get("findingCounts") or {}).get("critical", 0),
                "top_rule_ids": top_rules,
                "uncertain_reasons": "; ".join(results.get("uncertainReasons", [])),
                "errors": "; ".join(results.get("errors", [])),
            }
        )

    output_csv.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "analysis_folder",
        "mod_id",
        "mod_name",
        "mod_version",
        "mod_url",
        "uploaded_at",
        "checked_at",
        "status",
        "risk_score",
        "findings_total",
        "findings_low",
        "findings_medium",
        "findings_high",
        "findings_critical",
        "top_rule_ids",
        "uncertain_reasons",
        "errors",
    ]
    with output_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    return len(rows)

