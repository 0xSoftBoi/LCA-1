# SPDX-License-Identifier: Apache-2.0
"""Power-trace contract between LCA-1 and VoltForge.

The model integrates calibrated or measured samples. It intentionally ships no
default watts-per-operation constants that could be mistaken for evidence.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

ALLOWED_STATES = {"idle", "kem", "dsa", "dma", "zeroize", "fault"}


@dataclass(frozen=True)
class ActivitySample:
    timestamp_ns: int
    state: str
    active_lanes: int
    clock_hz: int
    estimated_watts: float | None = None
    measured_watts: float | None = None

    def validate(self) -> None:
        if self.timestamp_ns < 0:
            raise ValueError("timestamp_ns must be non-negative")
        if self.state not in ALLOWED_STATES:
            raise ValueError(f"unsupported activity state: {self.state}")
        if self.active_lanes < 0:
            raise ValueError("active_lanes must be non-negative")
        if self.clock_hz <= 0:
            raise ValueError("clock_hz must be positive")
        for name, value in (("estimated_watts", self.estimated_watts), ("measured_watts", self.measured_watts)):
            if value is not None and value < 0:
                raise ValueError(f"{name} must be non-negative")


@dataclass
class PowerTrace:
    source: str
    hardware_id: str
    operation: str
    samples: list[ActivitySample] = field(default_factory=list)
    metadata: dict[str, str | int | float | bool] = field(default_factory=dict)

    def validate(self) -> None:
        if not self.source or not self.hardware_id or not self.operation:
            raise ValueError("source, hardware_id, and operation are required")
        previous = -1
        for sample in self.samples:
            sample.validate()
            if sample.timestamp_ns <= previous:
                raise ValueError("sample timestamps must be strictly increasing")
            previous = sample.timestamp_ns

    def integrate_joules(self, *, measured: bool) -> float:
        """Integrate a piecewise-linear watt trace with the trapezoid rule."""
        self.validate()
        if len(self.samples) < 2:
            raise ValueError("at least two samples are required")
        field_name = "measured_watts" if measured else "estimated_watts"
        values = [getattr(sample, field_name) for sample in self.samples]
        if any(value is None for value in values):
            raise ValueError(f"all samples require {field_name}")

        joules = 0.0
        for left, right, p_left, p_right in zip(
            self.samples,
            self.samples[1:],
            values,
            values[1:],
        ):
            duration_s = (right.timestamp_ns - left.timestamp_ns) / 1_000_000_000
            joules += duration_s * (float(p_left) + float(p_right)) / 2
        return joules

    def to_json(self, path: Path) -> None:
        self.validate()
        payload = {
            "schema_version": "1.0",
            "source": self.source,
            "hardware_id": self.hardware_id,
            "operation": self.operation,
            "metadata": self.metadata,
            "samples": [asdict(sample) for sample in self.samples],
        }
        path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
