#!/usr/bin/env python3
"""Convert a little-endian firmware binary to one 32-bit readmemh word/line."""

from __future__ import annotations

import argparse
import pathlib


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    data += bytes((-len(data)) % 4)
    words = [
        int.from_bytes(data[offset : offset + 4], "little")
        for offset in range(0, len(data), 4)
    ]
    args.output.write_text("".join(f"{word:08x}\n" for word in words), encoding="ascii")


if __name__ == "__main__":
    main()
