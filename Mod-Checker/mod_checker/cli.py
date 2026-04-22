from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

from mod_checker.report import build_csv_report
from mod_checker.scanner import Scanner
from mod_checker.source_modworkshop import ModWorkshopSource
from mod_checker.storage import AnalysisStorage


DEFAULT_SOURCE_URL = "https://modworkshop.net/g/road-to-vostok"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="mod-checker", description="Road to Vostok mod scanner")
    subparsers = parser.add_subparsers(dest="command", required=True)

    scan = subparsers.add_parser("scan", help="Scan newest mod versions")
    scan.add_argument("--source", default="roadtovostok", choices=["roadtovostok"])
    scan.add_argument("--base-url", default=DEFAULT_SOURCE_URL)
    scan.add_argument("--limit", type=int, default=50)
    scan.add_argument("--all", action="store_true", help="Scan all pages for the source listing")
    scan.add_argument("--batch-size", type=int, default=1, help="Number of mods to process per run (default: 1)")
    scan.add_argument("--since", type=str, default=None, help="ISO datetime filter")
    scan.add_argument("--force", action="store_true", help="Rescan versions even if analyses folder exists")
    scan.add_argument("--dry-run", action="store_true", help="Print queue without scanning")
    scan.add_argument("--only-mod-id", type=str, default=None)
    scan.add_argument(
        "--analyses-root",
        default="Analyses",
        help="Analysis folder root. Defaults to Mod-Checker/Analyses when run from project root.",
    )

    scannext = subparsers.add_parser("scannext", help="Scan the single most recent unscanned mod-version")
    scannext.add_argument("--source", default="roadtovostok", choices=["roadtovostok"])
    scannext.add_argument("--base-url", default=DEFAULT_SOURCE_URL)
    scannext.add_argument("--limit", type=int, default=200)
    scannext.add_argument("--all", action="store_true", help="Traverse all listing pages")
    scannext.add_argument("--since", type=str, default=None, help="ISO datetime filter")
    scannext.add_argument("--force", action="store_true", help="Rescan versions even if analyses folder exists")
    scannext.add_argument(
        "--analyses-root",
        default="Analyses",
        help="Analysis folder root. Defaults to Mod-Checker/Analyses when run from project root.",
    )

    scanremaining = subparsers.add_parser(
        "scannremaining",
        help="Scan all remaining unscanned mod-versions one-by-one with progress bar",
    )
    scanremaining.add_argument("--source", default="roadtovostok", choices=["roadtovostok"])
    scanremaining.add_argument("--base-url", default=DEFAULT_SOURCE_URL)
    scanremaining.add_argument("--limit", type=int, default=10000)
    scanremaining.add_argument("--all", action="store_true", help="Traverse all listing pages")
    scanremaining.add_argument("--since", type=str, default=None, help="ISO datetime filter")
    scanremaining.add_argument("--force", action="store_true", help="Rescan versions even if analyses folder exists")
    scanremaining.add_argument(
        "--analyses-root",
        default="Analyses",
        help="Analysis folder root. Defaults to Mod-Checker/Analyses when run from project root.",
    )

    report = subparsers.add_parser("report", help="Build CSV report from analyses")
    report.add_argument(
        "--analyses-root",
        default="Analyses",
        help="Analysis folder root. Defaults to Mod-Checker/Analyses when run from project root.",
    )
    report.add_argument(
        "--output",
        default="Analyses/Summary.csv",
        help="CSV output path relative to Mod-Checker unless absolute path.",
    )

    candidates = subparsers.add_parser("candidates", help="List next unscanned mod-version candidates")
    candidates.add_argument("--source", default="roadtovostok", choices=["roadtovostok"])
    candidates.add_argument("--base-url", default=DEFAULT_SOURCE_URL)
    candidates.add_argument("--limit", type=int, default=50)
    candidates.add_argument("--all", action="store_true", help="Traverse all listing pages")
    candidates.add_argument("--since", type=str, default=None, help="ISO datetime filter")
    candidates.add_argument("--only-mod-id", type=str, default=None)
    candidates.add_argument(
        "--analyses-root",
        default="Analyses",
        help="Analysis folder root. Defaults to Mod-Checker/Analyses when run from project root.",
    )
    candidates.add_argument("--format", choices=["text", "json", "csv"], default="text")
    candidates.add_argument("--output", default=None, help="Optional output path for json/csv export")
    return parser


def main(argv: list[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "scan":
        run_scan(args)
    if args.command == "scannext":
        run_scannext(args)
    if args.command == "scannremaining":
        run_scannremaining(args)
    if args.command == "report":
        run_report(args)
    if args.command == "candidates":
        run_candidates(args)


def run_scan(args: argparse.Namespace) -> None:
    source = ModWorkshopSource(base_url=args.base_url)
    effective_limit = 10000 if args.all else args.limit
    entries = source.fetch_newest(limit=effective_limit, only_mod_id=args.only_mod_id, all_pages=args.all)
    since_dt = parse_iso_datetime(args.since) if args.since else None
    if since_dt:
        entries = [item for item in entries if item.uploaded_at >= since_dt]

    storage = AnalysisStorage(resolve_analyses_root(args.analyses_root))
    queue = entries if args.force else [item for item in entries if not storage.exists(item)]
    queue = queue[: max(1, args.batch_size)]

    print(f"Fetched: {len(entries)} | Queued: {len(queue)} | Force: {args.force} | BatchSize: {max(1, args.batch_size)}")
    if not queue:
        print("No pending mod versions to scan.")
        return
    if args.dry_run:
        for item in queue:
            print(f"DRY-RUN {item.mod_id} {item.mod_name} {item.mod_version} {item.mod_url}")
        return

    scanner = Scanner()
    successes = 0
    for item in queue:
        print(f"Scanning {item.mod_id} {item.mod_name} {item.mod_version}")
        result, extracted_dir = scanner.scan(item)
        out_dir = storage.write_analysis(item, result, extracted_dir)
        print(f" -> {result.status.upper()} score={result.risk_score} output={out_dir}")
        successes += 1

    print(f"Completed {successes} scan(s).")


def run_report(args: argparse.Namespace) -> None:
    analyses_root = resolve_analyses_root(args.analyses_root)
    output_path = resolve_output_path(args.output)
    row_count = build_csv_report(analyses_root=analyses_root, output_csv=output_path)
    print(f"Wrote report: {output_path} ({row_count} row(s))")


def run_scannext(args: argparse.Namespace) -> None:
    source = ModWorkshopSource(base_url=args.base_url)
    effective_limit = 10000 if args.all else args.limit
    entries = source.fetch_newest(limit=effective_limit, all_pages=args.all)
    since_dt = parse_iso_datetime(args.since) if args.since else None
    if since_dt:
        entries = [item for item in entries if item.uploaded_at >= since_dt]

    storage = AnalysisStorage(resolve_analyses_root(args.analyses_root))
    queue = entries if args.force else [item for item in entries if not storage.exists(item)]
    if not queue:
        print("No pending mod versions to scan.")
        return

    target = queue[0]
    print(f"Scanning next candidate: {target.mod_id} {target.mod_name} {target.mod_version}")
    scanner = Scanner()
    result, extracted_dir = scanner.scan(target)
    out_dir = storage.write_analysis(target, result, extracted_dir)
    print(f" -> {result.status.upper()} score={result.risk_score} output={out_dir}")
    print("Completed 1 scan(s).")


def run_scannremaining(args: argparse.Namespace) -> None:
    try:
        from tqdm import tqdm
    except ModuleNotFoundError as exc:
        raise SystemExit("Missing dependency: tqdm. Install with `pip install -e .` from Mod-Checker.") from exc

    source = ModWorkshopSource(base_url=args.base_url)
    effective_limit = 10000 if args.all else args.limit
    discovered_total = source.fetch_total_mod_count()
    progress_total = effective_limit
    if discovered_total is not None:
        progress_total = min(effective_limit, discovered_total)
    since_dt = parse_iso_datetime(args.since) if args.since else None
    storage = AnalysisStorage(resolve_analyses_root(args.analyses_root))
    scanner = Scanner()
    completed = 0
    scanned_or_skipped = 0

    progress = tqdm(total=progress_total, desc="Scanning remaining mods", unit="mod")
    for item in source.iter_newest(limit=effective_limit, all_pages=args.all):
        scanned_or_skipped += 1
        progress.update(1)
        if since_dt and item.uploaded_at < since_dt:
            continue
        if not args.force and storage.exists(item):
            continue
        result, extracted_dir = scanner.scan(item)
        # Persist each mod immediately so interruptions still keep finished analyses.
        storage.write_analysis(item, result, extracted_dir)
        completed += 1
        progress.set_postfix(done=completed)
    progress.close()
    if scanned_or_skipped == 0:
        print("No mod versions were fetched.")
        return
    if completed == 0:
        print("No pending mod versions to scan.")
        return
    print(f"Completed {completed} scan(s).")


def run_candidates(args: argparse.Namespace) -> None:
    source = ModWorkshopSource(base_url=args.base_url)
    effective_limit = 10000 if args.all else args.limit
    entries = source.fetch_newest(limit=effective_limit, only_mod_id=args.only_mod_id, all_pages=args.all)
    since_dt = parse_iso_datetime(args.since) if args.since else None
    if since_dt:
        entries = [item for item in entries if item.uploaded_at >= since_dt]
    storage = AnalysisStorage(resolve_analyses_root(args.analyses_root))
    candidates = [item for item in entries if not storage.exists(item)]

    rows = [
        {
            "mod_id": item.mod_id,
            "mod_name": item.mod_name,
            "mod_version": item.mod_version,
            "mod_url": item.mod_url,
            "uploaded_at": item.uploaded_at.isoformat(),
        }
        for item in candidates
    ]

    if args.format == "text":
        print(f"Candidates: {len(rows)}")
        for row in rows:
            print(f"{row['mod_id']} | {row['mod_name']} | {row['mod_version']} | {row['mod_url']}")
        return

    output_path = resolve_output_path(args.output) if args.output else None
    if args.format == "json":
        content = json.dumps(rows, indent=2)
        if output_path:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_text(content + "\n", encoding="utf-8")
            print(f"Wrote candidates JSON: {output_path} ({len(rows)} row(s))")
        else:
            print(content)
        return

    if args.format == "csv":
        fieldnames = ["mod_id", "mod_name", "mod_version", "mod_url", "uploaded_at"]
        if output_path:
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with output_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=fieldnames)
                writer.writeheader()
                writer.writerows(rows)
            print(f"Wrote candidates CSV: {output_path} ({len(rows)} row(s))")
        else:
            writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)


def resolve_analyses_root(user_path: str) -> Path:
    base = Path(user_path)
    if base.is_absolute():
        return base
    cwd = Path.cwd()
    if cwd.name == "Mod-Checker":
        return cwd / user_path
    return cwd / "Mod-Checker" / user_path


def parse_iso_datetime(value: str) -> datetime:
    normalized = value.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise SystemExit(f"Invalid --since datetime: {value}") from exc
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC)


def resolve_output_path(value: str) -> Path:
    path = Path(value)
    if path.is_absolute():
        return path
    cwd = Path.cwd()
    if cwd.name == "Mod-Checker":
        return cwd / value
    return cwd / "Mod-Checker" / value


if __name__ == "__main__":
    main(sys.argv[1:])

