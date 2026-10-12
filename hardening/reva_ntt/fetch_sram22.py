#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fetch and verify the pinned SRAM22 collateral used by Rev-A NTT hardening."""

from __future__ import annotations

import gzip
import hashlib
import sys
import urllib.request
from pathlib import Path

SOURCE_REPO = "ucb-substrate/sram22_sky130_macros"
SOURCE_COMMIT = "75cbe961e18ee00d5a6c73fa455505f0bcdf4c05"
MACRO = "sram22_128x32m4w8"
BASE = f"https://raw.githubusercontent.com/{SOURCE_REPO}/{SOURCE_COMMIT}/{MACRO}"

# Git blob SHA-1 values from the pinned repository commit. Verifying Git's blob
# object hash catches both transport corruption and upstream path drift while
# keeping the large GDS outside this repository.
FILES = {
    f"{MACRO}.v": "c5319f5d6e44cfe81a8fe279e67feab04da46f1a",
    f"{MACRO}.lef": "7e2448ea9337f61872067142d9f63f5924460159",
    f"{MACRO}.gds.gz": "eecbb17fec7e20fd93bbee88f6a5d6f22036237d",
    f"{MACRO}.spice": "edad247e769a7c8204ecc192ef8e6e867a6b3c42",
    f"{MACRO}_tt_025C_1v80.lib": "f075318607ad7db1c4f4922ab03fe3622e7d2a9e",
    f"{MACRO}_ss_100C_1v60.lib": "69314ddaebd545ea3a2b8d654afaaf9f002c4639",
    f"{MACRO}_ff_n40C_1v95.lib": "9979fdfc41fb1f54d5ad58f05631403d195041ca",
}


def git_blob_sha(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def main() -> int:
    out = Path(__file__).resolve().parent / "macros" / MACRO
    out.mkdir(parents=True, exist_ok=True)

    for name, expected in FILES.items():
        url = f"{BASE}/{name}"
        print(f"fetch {url}")
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        actual = git_blob_sha(data)
        if actual != expected:
            print(f"ERROR {name}: git blob {actual} != pinned {expected}", file=sys.stderr)
            return 1
        (out / name).write_bytes(data)
        print(f"  verified git-blob-sha1={actual} bytes={len(data)}")

    gz_path = out / f"{MACRO}.gds.gz"
    gds_path = out / f"{MACRO}.gds"
    gds_path.write_bytes(gzip.decompress(gz_path.read_bytes()))
    print(f"  unpacked {gds_path.name} sha256={hashlib.sha256(gds_path.read_bytes()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
