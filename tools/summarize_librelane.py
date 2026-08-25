#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Extract a stable, reviewable subset of LibreLane final metrics."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

INTEREST = (
    "timing",
    "area",
    "utilization",
    "power",
    "drc",
    "lvs",
    "antenna",
    "wirelength",
    "clock",
    "slew",
    "capacitance",
)


def latest_metrics(design_dir: Path) -> Path:
    candidates = list(design_dir.glob("runs/*/final/metrics.json"))
    if not candidates:
        raise FileNotFoundError(f"no LibreLane final/metrics.json below {design_dir}")
    return max(candidates, key=lambda path: path.stat().st_mtime_ns)


def scalar(value: Any) -> bool:
    return value is None or isinstance(value, (bool, int, float, str))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("design", nargs="+")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    workspace = args.workspace.resolve()
    summary: dict[str, Any] = {}
    for design in args.design:
        metrics_path = latest_metrics(workspace / "openlane" / design)
        metrics = json.loads(metrics_path.read_text())
        selected = {
            key: value
            for key, value in sorted(metrics.items())
            if scalar(value) and any(token in key.lower() for token in INTEREST)
        }
        summary[design] = {
            "metrics_path": metrics_path.relative_to(workspace).as_posix(),
            "metrics": selected,
        }

    rendered = json.dumps(summary, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
