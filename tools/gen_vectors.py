#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Generate the deterministic LCA-1 butterfly RTL regression corpus."""

from __future__ import annotations

import argparse
import hashlib
import random
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from model.modarith import DSA_Q, KEM_Q, WORD_BITS, butterfly

FORMAT_VERSION = 1
SEED = 0x1CA1E001
RANDOM_CASES_PER_MODULUS = 128
DEFAULT_OUTPUT = ROOT / "verification" / "vectors" / "butterfly_vectors.txt"


@dataclass(frozen=True)
class Vector:
    case_id: int
    modulus_id: int
    a: int
    b: int
    twiddle: int
    expected_a: int
    expected_b: int
    expected_fault: int
    hold_cycles: int
    expected_latency: int

    def line(self) -> str:
        return " ".join(str(value) for value in self.__dict__.values())


def _valid_case(
    case_id: int,
    modulus_id: int,
    modulus: int,
    a: int,
    b: int,
    twiddle: int,
) -> Vector:
    result = butterfly(a, b, twiddle, modulus)
    return Vector(
        case_id=case_id,
        modulus_id=modulus_id,
        a=a,
        b=b,
        twiddle=twiddle,
        expected_a=result.out_a,
        expected_b=result.out_b,
        expected_fault=0,
        hold_cycles=(case_id * 7) % 4,
        expected_latency=WORD_BITS,
    )


def build_vectors() -> list[Vector]:
    rng = random.Random(SEED)
    vectors: list[Vector] = []

    for modulus_id, modulus in enumerate((KEM_Q, DSA_Q)):
        edge_inputs = (
            (0, 0, 0),
            (1, 0, 0),
            (0, 1, 1),
            (1, 2, 3),
            (modulus - 1, 0, modulus - 1),
            (modulus - 1, modulus - 1, modulus - 1),
            (modulus // 2, modulus // 3, modulus // 5),
            (1234567 % modulus, 7654321 % modulus, 543210 % modulus),
        )
        for a, b, twiddle in edge_inputs:
            vectors.append(
                _valid_case(len(vectors), modulus_id, modulus, a, b, twiddle)
            )
        for _ in range(RANDOM_CASES_PER_MODULUS):
            vectors.append(
                _valid_case(
                    len(vectors),
                    modulus_id,
                    modulus,
                    rng.randrange(modulus),
                    rng.randrange(modulus),
                    rng.randrange(modulus),
                )
            )

    invalid_inputs = (
        (0, KEM_Q, 0, 0),
        (0, 0, KEM_Q, 0),
        (0, 0, 0, KEM_Q),
        (1, DSA_Q, 0, 0),
        (1, 0, DSA_Q, 0),
        (1, 0, 0, DSA_Q),
        (2, 0, 0, 0),
        (3, 0, 0, 0),
    )
    for modulus_id, a, b, twiddle in invalid_inputs:
        case_id = len(vectors)
        vectors.append(
            Vector(
                case_id=case_id,
                modulus_id=modulus_id,
                a=a,
                b=b,
                twiddle=twiddle,
                expected_a=0,
                expected_b=0,
                expected_fault=1,
                hold_cycles=(case_id % 3) + 1,
                expected_latency=0,
            )
        )

    return vectors


def render(vectors: list[Vector]) -> str:
    header = f"{FORMAT_VERSION} {len(vectors)} {SEED}"
    return header + "\n" + "\n".join(vector.line() for vector in vectors) + "\n"


def _digest(content: str) -> str:
    return hashlib.sha256(content.encode("utf-8")).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if the committed corpus is missing or differs",
    )
    args = parser.parse_args()

    vectors = build_vectors()
    content = render(vectors)
    output = args.output.resolve()

    if args.check:
        if not output.exists():
            print(f"ERROR missing generated corpus: {output}", file=sys.stderr)
            return 1
        actual = output.read_text(encoding="utf-8")
        if actual != content:
            print(
                "ERROR generated corpus drift: "
                f"expected sha256={_digest(content)} actual sha256={_digest(actual)}",
                file=sys.stderr,
            )
            return 1
        print(
            f"PASS vector corpus: {len(vectors)} cases, seed=0x{SEED:08x}, "
            f"sha256={_digest(content)}"
        )
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    print(
        f"WROTE {output}: {len(vectors)} cases, seed=0x{SEED:08x}, "
        f"sha256={_digest(content)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
