# RTV Mod Checker

CLI scanner for Road to Vostok mods from ModWorkshop.

The checker downloads mod files, inspects archive contents statically (no execution), applies security-focused rules, and writes per-mod analysis artifacts plus a summary CSV report.

## Features

- Fetches latest mods from `https://modworkshop.net/g/road-to-vostok`
- Static inspection of:
  - zip archives
  - rar archives (when rar backend support is available)
  - plain/text payloads
- Flags risky file types (`.exe`, `.dll`, scripts, launchers, etc.)
- Content pattern checks (execution, suspicious domains, obfuscation indicators, risky paths)
- Mod-specific checks (`mod.txt`, `override.cfg`, loader-aware behavior handling)
- Optional GitHub repository context scan for executable-based mods
- Generates:
  - `Analyses/<mod-folder>/metadata.json`
  - `Analyses/<mod-folder>/scan-results.json`
  - `Analyses/<mod-folder>/scan-summary.md`
  - `Analyses/Summary.csv`

## Statuses

- `clean` - no meaningful danger signals found
- `uncertain` - not enough evidence to classify safe/unsafe confidently
- `suspicious` - risky behavior/signals found; manual review required
- `malicious` - critical signals strongly indicate unsafe behavior
- `error` - scan could not complete for that mod

## Requirements

- Python 3.10+
- Recommended: virtual environment (`.venv`)
- For RAR extraction support:
  - Python package `rarfile` (already listed in project deps)
  - system backend (`unrar` or `bsdtar`)

## Installation

From this folder (`Mod-Checker`):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

Verify CLI:

```bash
python3 -m mod_checker.cli --help
```

## Common Commands

### Scan all remaining mods (full pass)

```bash
python3 -m mod_checker.cli scannremaining --all
```

### Build/refresh summary CSV

```bash
python3 -m mod_checker.cli report
```

### Scan one specific mod id

```bash
python3 -m mod_checker.cli scan --only-mod-id 56056 --force
```

### Scan next unscanned mod

```bash
python3 -m mod_checker.cli scannext
```

### List candidates without scanning

```bash
python3 -m mod_checker.cli candidates --all
```

## Convenience Script (repo root)

From repo root, there is also:

```bash
./scan.sh
```

It activates the venv, runs:

- `python3 -m mod_checker.cli scannremaining --all`
- `python3 -m mod_checker.cli report`

## Output Layout

- `Analyses/Summary.csv` - high-level report used for triage
- `Analyses/<mod-id-name-version>/metadata.json` - mod metadata + download source
- `Analyses/<mod-id-name-version>/scan-results.json` - normalized machine-readable findings
- `Analyses/<mod-id-name-version>/scan-summary.md` - human-readable report

## Notes

- This is a static scanner, not a guarantee of safety.
- Native binaries (`.exe`, `.dll`, etc.) should be treated with extra caution.
- Linked source repositories provide useful context but do not automatically prove binary provenance.
