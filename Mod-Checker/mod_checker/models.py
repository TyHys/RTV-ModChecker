from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class ModEntry:
    mod_id: str
    mod_name: str
    mod_version: str
    mod_url: str
    uploaded_at: datetime
    download_url: str | None = None
    author_name: str | None = None
    author_id: str | None = None
    source: str = "roadtovostok"


@dataclass(frozen=True)
class Finding:
    rule_id: str
    severity: str
    title: str
    evidence: str
    recommendation: str
    file_path: str | None = None
    code_excerpt: str | None = None


@dataclass
class ScanResult:
    status: str
    risk_score: int
    findings: list[Finding] = field(default_factory=list)
    archive_sha256: str | None = None
    errors: list[str] = field(default_factory=list)
    uncertain_reasons: list[str] = field(default_factory=list)
    extracted_dir: Path | None = None

    def finding_counts(self) -> dict[str, int]:
        counts = {"low": 0, "medium": 0, "high": 0, "critical": 0}
        for finding in self.findings:
            counts[finding.severity] = counts.get(finding.severity, 0) + 1
        return counts

    def to_json_dict(self, engine_version: str) -> dict[str, Any]:
        return {
            "status": self.status,
            "riskScore": self.risk_score,
            "findingCounts": self.finding_counts(),
            "findings": [
                {
                    "ruleId": f.rule_id,
                    "severity": f.severity,
                    "title": f.title,
                    "evidence": f.evidence,
                    "recommendation": f.recommendation,
                    "filePath": f.file_path,
                    "codeExcerpt": f.code_excerpt,
                }
                for f in self.findings
            ],
            "engineVersion": engine_version,
            "errors": self.errors,
            "uncertainReasons": self.uncertain_reasons,
        }

