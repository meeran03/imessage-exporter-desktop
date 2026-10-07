#!/usr/bin/env python3
"""Package only explicitly allowlisted project/source files. Never include local libraries."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "0.1.0"
ALLOWED_FILES = ["Package.swift", "README.md", "LICENSE", "CONTRIBUTING.md", "PRIVACY.md", "SECURITY.md", ".gitignore"]
ALLOWED_FOLDERS = ["Sources", "Tests", "scripts", ".github", "docs"]


def main():
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    upstream = ROOT / "ThirdParty/imessage-exporter-4.3.0"
    if not (upstream / "vendor").is_dir():
        raise RuntimeError("Run scripts/vendor-engine.py before packaging corresponding source")
    source_zip = dist / f"iMessage-Exporter-{VERSION}-source.zip"
    items = [ROOT / name for name in ALLOWED_FILES]
    for folder in ALLOWED_FOLDERS:
        items += [p for p in (ROOT / folder).rglob("*") if p.is_file()]
    items += [ROOT / "ThirdParty/NOTICE.md", ROOT / "ThirdParty/SHA256SUMS"]
    items += [p for p in upstream.rglob("*") if p.is_file() and '.git' not in p.parts and 'target' not in p.parts]
    # Reject local export artifacts even if they are accidentally placed in an allowlisted directory.
    for path in items:
        if path.suffix in (".db", ".sqlite", ".abcddb", ".log") and upstream not in path.parents:
            raise RuntimeError("Unexpected private-data artifact in source input: " + str(path))
        if path.is_symlink():
            raise RuntimeError("Source artifacts must not contain symlinks")
    with zipfile.ZipFile(source_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for path in sorted(set(items)):
            z.write(path, "imessage-exporter-desktop/" + str(path.relative_to(ROOT)))
    with zipfile.ZipFile(source_zip) as z:
        if z.testzip() is not None:
            raise RuntimeError("Source archive verification failed")
    files = sorted(dist.glob(f"iMessage-Exporter-{VERSION}-*.zip"))
    checksums = "".join(hashlib.sha256(p.read_bytes()).hexdigest() + "  " + p.name + "\n" for p in files)
    (dist / "SHA256SUMS").write_text(checksums)
    print(f"Created source archive with {len(set(items))} files and SHA256SUMS.")


if __name__ == "__main__":
    main()
