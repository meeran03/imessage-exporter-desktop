#!/usr/bin/env python3
"""Archive every Cargo.lock dependency's source for offline rebuilds and licensing."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import io
import json
import re
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ThirdParty/imessage-exporter-4.3.0"
VENDOR = SOURCE / "vendor"


def fetch(package):
    name, version, checksum = package
    folder = VENDOR / f"{name}-{version}"
    marker = folder / ".cargo-checksum.json"
    if marker.exists() and json.loads(marker.read_text()).get("package") == checksum:
        return
    url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
    request = urllib.request.Request(url, headers={"User-Agent": "MessageArchive-source-bundle"})
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != checksum:
        raise RuntimeError("Dependency checksum mismatch: " + name)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tar:
        for member in tar.getmembers():
            path = VENDOR / member.name
            if folder.resolve() not in path.resolve().parents and path.resolve() != folder.resolve():
                raise RuntimeError("Unsafe crate member")
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                path.parent.mkdir(parents=True, exist_ok=True)
                stream = tar.extractfile(member)
                path.write_bytes(stream.read())
                path.chmod(member.mode & 0o777)
            else:
                raise RuntimeError("Unsupported crate link")
    files = {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in folder.rglob("*") if p.is_file() and p.name != ".cargo-checksum.json"}
    marker.write_text(json.dumps({"files": files, "package": checksum}, sort_keys=True))


def main():
    packages = []
    for block in (SOURCE / "Cargo.lock").read_text().split("[[package]]")[1:]:
        fields = dict(re.findall(r'^([a-z]+) = "([^"\n]+)"$', block, flags=re.M))
        if "source" not in fields:
            continue
        if fields["source"] != "registry+https://github.com/rust-lang/crates.io-index":
            raise RuntimeError("Unsupported source dependency: " + fields["source"])
        packages.append((fields["name"], fields["version"], fields["checksum"]))
    VENDOR.mkdir(exist_ok=True)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(fetch, packages))
    config = SOURCE / ".cargo/config.toml"
    config.parent.mkdir(exist_ok=True)
    config.write_text('[source.crates-io]\nreplace-with = "vendored-sources"\n\n'
                      '[source.vendored-sources]\ndirectory = "vendor"\n')
    print(f"Vendored and verified source for {len(packages)} locked dependencies.")


if __name__ == "__main__":
    main()
