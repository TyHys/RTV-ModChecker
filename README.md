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

## Detailed Checks Performed

The scanner runs these checks today:

- **Archive structure and parsing checks**
  - Detects zip-slip/path traversal archive entries (for example absolute paths or `../`)  
    - Rule: `ARCHIVE-TRAVERSAL-001` (critical)
  - Tries to parse:
    - zip archives
    - rar archives (if rar tooling is available)
  - If package format cannot be fully inspected, reports an informational uncertainty finding  
    - Rule: `ARCHIVE-001` (low)

- **Blocked/risky file extension checks**
  - Flags native binaries:
    - `.exe`, `.dll`, `.so`, `.dylib`
    - Rule: `ARCHIVE-NATIVE-001` (high)
  - Flags high-risk script/launcher payloads:
    - `.ps1`, `.psm1`, `.cmd`, `.msi`, `.vbs`, `.jse`, `.wsf`, `.lnk`, `.scr`, `.com`
    - Rule: `ARCHIVE-EXEC-001` (critical/high)
  - Flags JavaScript payload files:
    - `.js`
    - Rule: `ARCHIVE-EXEC-003` (high)
  - Special handling for batch files (`.bat`):
    - obvious command/network indicators -> medium
    - local helper/empty batch file -> low
    - Rule: `ARCHIVE-EXEC-002`

- **Content pattern checks inside text/script files**
  - Process execution APIs  
    - Rule: `EXEC-001`
  - `cmd.exe` command invocation patterns  
    - Rule: `CMD-001`
  - Network API indicators (`HTTPRequest`, TCP/UDP/websocket classes)  
    - Rule: `NET-001`
  - PowerShell execution patterns  
    - Rule: `PS-001`
  - Known malicious domain indicator (`roadtovostok.store`)  
    - Rule: `IOC-001`
  - Obfuscation-style indicators (`base64`, `_0x...`, `xor`, etc.) with benign-context filtering  
    - Rule: `OBF-001`
  - Encoded numeric payload arrays  
    - Rule: `OBF-002`
  - Suspicious absolute/system path references (`%APPDATA%`, `%TEMP%`, registry run keys, startup paths, etc.)  
    - Rule: `PATH-001`

- **Godot/manifest/config specific checks**
  - `mod.txt` update metadata sanity (`modworkshop=` format)  
    - Rule: `MANIFEST-URL-001` (low)
  - `mod.txt` traversal markers (`..`)  
    - Rule: `MANIFEST-PATH-001` (critical)
  - `override.cfg` classification:
    - risky entries -> high
    - routine local autoload config -> low
    - Rule: `OVERRIDE-001`

- **Context-aware behavior checks**
  - `OS.shell_open(...)` is classified by destination type:
    - known attacker domain -> critical
    - external unknown URL -> high
    - local path / trusted modworkshop link -> low
    - Rule: `EXEC-002`
  - `load_resource_pack(...)`:
    - normal runtime pack-loading outside known loader context -> critical
    - recognized loader/framework context -> low
    - Rule: `PACK-001`

- **Binary resource extraction checks**
  - For known binary Godot resource extensions (`.res`, `.scn`, `.ctex`, `.import`, `.mesh`, `.anim`), extracts readable strings and scans them.
  - Adds an informational marker when this pipeline runs:
    - Rule: `DESER-001` (low)

- **Executable provenance context checks**
  - If mod download is native executable-based, scanner tries to find linked GitHub repository on mod page.
  - If found, scanner downloads repo source archive and scans it as context.
  - Emits informational provenance/context finding:
    - Rule: `GITHUB-REPO-001` (low)
  - This improves context, but does **not** prove binary and source are identical.

- **De-duplication and scoring**
  - Duplicate findings are collapsed by rule/severity/title/evidence/path.
  - Status scoring is severity-driven with uncertainty handling:
    - critical findings -> `malicious`
    - high/medium findings -> `suspicious`
    - low-only uncertainty signals (for example unverifiable archive/provenance) -> `uncertain`
    - otherwise -> `clean`

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
