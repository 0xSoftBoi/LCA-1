#!/usr/bin/env python3
"""Generate deterministic package and ATE CSVs from the Rev-A JSON contract."""

from __future__ import annotations

import argparse
import csv
import io
import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_PATH = Path("fabrication/rev_a_package.json")
GENERATED_ROOT = Path("fabrication/generated")


def _csv_text(headers: list[str], rows: list[list[Any]]) -> str:
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\n")
    writer.writerow(headers)
    writer.writerows(rows)
    return stream.getvalue()


def generate(package: dict[str, Any]) -> dict[Path, str]:
    def pin_key(pin: dict[str, Any]) -> tuple[int, int]:
        return (1, 0) if pin["pin"] == "EP" else (0, int(pin["pin"]))

    pin_rows = [
        [pin["pin"], pin["name"], pin["role"], pin["nominal_voltage"], pin["notes"]]
        for pin in sorted(package["qfn_pinout"], key=pin_key)
    ]
    gpio_rows = [
        [
            row["gpio"],
            row["qfn_pin"],
            row["signal"],
            row["direction"],
            row["dm"],
            row["oeb"],
            row["inp_dis"],
            row["ib_mode_sel"],
            row["vtrip_sel"],
            row["slow"],
            row["safe_state"],
        ]
        for row in sorted(package["logical_io"], key=lambda item: item["gpio"])
    ]
    ate_rows = [
        [row["id"], row["stage"], row["stimulus"], row["expected"], row["fixture"], row["status"]]
        for row in package["ate_tests"]
    ]
    return {
        GENERATED_ROOT / "rev_a_qfn_pinout.csv": _csv_text(
            ["package_pin", "pad_name", "role", "nominal_voltage", "notes"], pin_rows
        ),
        GENERATED_ROOT / "rev_a_gpio_map.csv": _csv_text(
            ["gpio", "qfn_pin", "signal", "direction", "dm", "oeb", "inp_dis", "ib_mode_sel", "vtrip_sel", "slow", "safe_state"],
            gpio_rows,
        ),
        GENERATED_ROOT / "rev_a_ate_plan.csv": _csv_text(
            ["test_id", "stage", "stimulus", "expected", "fixture", "status"], ate_rows
        ),
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument("--check", action="store_true", help="Fail if committed generated files differ")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    with (repo_root / PACKAGE_PATH).open("r", encoding="utf-8") as stream:
        package = json.load(stream)
    generated = generate(package)
    stale: list[str] = []
    for relative_path, content in generated.items():
        path = repo_root / relative_path
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != content:
                stale.append(relative_path.as_posix())
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8", newline="")
            print(f"wrote {relative_path.as_posix()}")
    if stale:
        print("generated fabrication artifacts are stale:", file=sys.stderr)
        for path in stale:
            print(f"  - {path}", file=sys.stderr)
        return 1
    if args.check:
        print(f"generated fabrication artifacts current: {len(generated)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
