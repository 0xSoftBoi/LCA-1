#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fetch the pinned SRAM22 physical views and verify Git blob identities.

This intentionally verifies Git object IDs instead of trusting transport URLs.
The manifest is the supply-chain contract; a floating branch is never used.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "physical" / "sram22" / "manifest.json"
DEFAULT_OUT = ROOT / "physical" / "sram22" / "vendor"


def git_blob_sha1(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode()
    return hashlib.sha1(header + data, usedforsecurity=False).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="verify already-fetched files without network access")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    repo = manifest["source"]["repository"]
    commit = manifest["source"]["commit"]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    failures = 0
    for macro in manifest["macros"].values():
        for view_name, view in macro["views"].items():
            rel = pathlib.Path(view["path"])
            dest = output / rel
            if args.check:
                if not dest.exists():
                    print(f"ERROR missing {dest}")
                    failures += 1
                    continue
                data = dest.read_bytes()
            else:
                url = f"https://raw.githubusercontent.com/{repo}/{commit}/{view['path']}"
                print(f"FETCH {url}")
                with urllib.request.urlopen(url, timeout=120) as response:
                    data = response.read()
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)

            actual = git_blob_sha1(data)
            expected = view["git_blob_sha1"]
            if actual != expected:
                print(f"ERROR {view_name} {view['path']}: expected {expected}, got {actual}")
                failures += 1
            else:
                print(f"PASS  {view['path']} git-blob={actual}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
