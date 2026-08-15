# SPDX-License-Identifier: Apache-2.0
"""Account for LCA-relevant work in one ETP bridge operation.

The tool intentionally accepts measured primitive data rather than embedding
performance estimates. It cannot turn a kernel timing into a bridge claim.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Mapping

PRIMITIVES = ("kem_encaps", "kem_decaps", "dsa_sign", "dsa_verify")


@dataclass(frozen=True)
class PrimitiveCounts:
    kem_encaps: int = 1
    kem_decaps: int = 1
    dsa_sign: int = 2
    dsa_verify: int = 2

    @classmethod
    def minimal(cls) -> "PrimitiveCounts":
        return cls(dsa_sign=1, dsa_verify=1)

    @classmethod
    def authenticated(cls) -> "PrimitiveCounts":
        return cls()

    def validate(self) -> None:
        for name, count in asdict(self).items():
            if not isinstance(count, int) or count < 0:
                raise ValueError(f"{name} count must be a non-negative integer")


@dataclass(frozen=True)
class PrimitiveMeasurement:
    latency_ns: float
    energy_uj: float | None = None

    def validate(self, name: str) -> None:
        if self.latency_ns < 0:
            raise ValueError(f"{name}.latency_ns must be non-negative")
        if self.energy_uj is not None and self.energy_uj < 0:
            raise ValueError(f"{name}.energy_uj must be non-negative")


def summarize(
    counts: PrimitiveCounts,
    measurements: Mapping[str, PrimitiveMeasurement],
    *,
    transfers: int = 1,
) -> dict[str, object]:
    counts.validate()
    if transfers <= 0:
        raise ValueError("transfers must be positive")
    missing = set(PRIMITIVES) - set(measurements)
    extra = set(measurements) - set(PRIMITIVES)
    if missing or extra:
        raise ValueError(f"measurement keys mismatch: missing={sorted(missing)}, extra={sorted(extra)}")

    count_map = asdict(counts)
    latency_ns = 0.0
    energy_uj = 0.0
    energy_complete = True
    breakdown: dict[str, dict[str, float | int | None]] = {}
    for name in PRIMITIVES:
        measurement = measurements[name]
        measurement.validate(name)
        count = count_map[name] * transfers
        total_latency = count * measurement.latency_ns
        total_energy = None
        if measurement.energy_uj is None:
            energy_complete = False
        else:
            total_energy = count * measurement.energy_uj
            energy_uj += total_energy
        latency_ns += total_latency
        breakdown[name] = {
            "count": count,
            "latency_ns": total_latency,
            "energy_uj": total_energy,
        }

    return {
        "transfers": transfers,
        "primitive_latency_sum_ns": latency_ns,
        "primitive_energy_sum_uj": energy_uj if energy_complete else None,
        "breakdown": breakdown,
        "claim_boundary": (
            "Primitive sums exclude host transfer, AEAD, Keccak outside the measured primitive, "
            "Merkle work, erasure coding, finality, replay checks, and execution."
        ),
    }


def _load_measurements(path: Path) -> dict[str, PrimitiveMeasurement]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("real_backend_active") is not True:
        raise ValueError("benchmark manifest must prove real_backend_active=true")
    return {
        name: PrimitiveMeasurement(**payload["measurements"][name])
        for name in PRIMITIVES
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("minimal", "authenticated"), default="authenticated")
    parser.add_argument("--transfers", type=int, default=1)
    parser.add_argument("--measurements", type=Path)
    args = parser.parse_args(argv)

    counts = PrimitiveCounts.minimal() if args.profile == "minimal" else PrimitiveCounts.authenticated()
    if args.measurements is None:
        print(json.dumps({"profile": args.profile, "counts": asdict(counts)}, indent=2, sort_keys=True))
        return 0

    result = summarize(counts, _load_measurements(args.measurements), transfers=args.transfers)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
