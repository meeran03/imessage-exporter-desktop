#!/usr/bin/env python3
"""Fetch checked, official source distributions for the bundled iPhone tools."""
from pathlib import Path
import hashlib
import json
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def main():
    destination = ROOT / "ThirdParty/iphone-source-archives"
    destination.mkdir(exist_ok=True)
    for item in json.loads((ROOT / "ThirdParty/iphone-sources.json").read_text()):
        path = destination / item["url"].rsplit("/", 1)[1]
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            request = urllib.request.Request(item["url"], headers={"User-Agent": "iMessageExporter-build"})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise RuntimeError("Source checksum mismatch: " + item["name"])
            path.write_bytes(data)
        print("Verified iPhone dependency: " + item["name"], flush=True)

if __name__ == "__main__":
    main()
