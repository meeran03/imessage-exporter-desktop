#!/usr/bin/env python3
"""Fetch pinned official engines and source, checking SHA-256 before use."""
from pathlib import Path
import hashlib
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = "4.3.0"
ASSETS = {
    "imessage-exporter-aarch64-apple-darwin": "7df7ed7618c30ffb805a0568bb4d300876191604e70686af333e67394152f815",
    "imessage-exporter-x86_64-apple-darwin": "e1ccb10cd60679e3e60e1f27972f0a7da39c6fe44bcb214cd4a9db3788377465",
}
SOURCE_HASH = "aaa19f21a3144bf9d115ce02a77a988bfdf3485fcd1d35cdb9ac4c81b86e2400"


def download(url, path, digest):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == digest:
        return
    request = urllib.request.Request(url, headers={"User-Agent": "MessageArchive-build"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise RuntimeError("Checksum mismatch for " + path.name)
    path.write_bytes(data)


def main():
    third_party = ROOT / "ThirdParty"
    for name, digest in ASSETS.items():
        download(f"https://github.com/ReagentX/imessage-exporter/releases/download/{VERSION}/{name}",
                 third_party / "binaries" / name, digest)
        (third_party / "binaries" / name).chmod(0o755)
    archive = third_party / f"imessage-exporter-{VERSION}.tar.gz"
    download(f"https://codeload.github.com/ReagentX/imessage-exporter/tar.gz/refs/tags/{VERSION}", archive, SOURCE_HASH)
    source = third_party / f"imessage-exporter-{VERSION}"
    if not (source / "Cargo.lock").exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                target = third_party / member.name
                if third_party.resolve() not in target.resolve().parents or member.issym() or member.islnk():
                    raise RuntimeError("Unsafe source archive member")
            tar.extractall(third_party)
    print(f"Verified official imessage-exporter {VERSION} for Apple Silicon and Intel.")


if __name__ == "__main__":
    main()
