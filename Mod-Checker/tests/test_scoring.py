from mod_checker.models import Finding
from mod_checker.scanner import score_from_findings


def test_score_critical_becomes_malicious():
    findings = [
        Finding(
            rule_id="X",
            severity="critical",
            title="critical",
            evidence="example",
            recommendation="reject",
        )
    ]
    status, score = score_from_findings(findings)
    assert status == "malicious"
    assert score >= 60


def test_score_none_is_clean():
    status, score = score_from_findings([])
    assert status == "clean"
    assert score == 0

