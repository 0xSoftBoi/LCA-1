#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Validate the Rev-A physical budget and pinned SRAM macro contract."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PHYSICAL = ROOT / "physical" / "rev_a_physical.json"
MANIFEST = ROOT / "physical" / "sram22" / "manifest.json"


def main() -> int:
    physical = json.loads(PHYSICAL.read_text())
    manifest = json.loads(MANIFEST.read_text())
    failures: list[str] = []

    if len(manifest["source"]["commit"]) != 40:
        failures.append("SRAM22 source must be pinned to a full 40-hex commit")
    if manifest["source"]["commit"] in {"main", "master", "HEAD"}:
        failures.append("floating SRAM22 ref is forbidden")

    expected_total = 0.0
    manifest_names = {entry["name"] for entry in manifest["macros"].values()}
    for macro in physical["macros"]:
        computed_each = macro["width_um"] * macro["height_um"] / 1_000_000.0
        computed_total = computed_each * macro["count"]
        expected_total += computed_total
        if abs(computed_each - macro["area_mm2_each"]) > 1e-9:
            failures.append(f"area drift for {macro['name']} each")
        if abs(computed_total - macro["area_mm2_total"]) > 1e-9:
            failures.append(f"area drift for {macro['name']} total")
        if macro["name"] not in manifest_names:
            failures.append(f"unmanifested physical macro {macro['name']}")

    if abs(expected_total - physical["macro_area_mm2_total"]) > 1e-9:
        failures.append("aggregate macro area drift")

    user_area = physical["openframe_user_area_mm2"]
    fraction = expected_total / user_area
    if fraction > physical["acceptance"]["max_macro_area_fraction"]:
        failures.append(
            f"macro area fraction {fraction:.3f} exceeds "
            f"{physical['acceptance']['max_macro_area_fraction']:.3f}"
        )
    if abs(fraction - physical["macro_area_fraction_of_user_area"]) > 1e-9:
        failures.append("macro area fraction drift")

    for family in manifest["macros"].values():
        required = {"verilog", "lef", "gds_gz", "lib_tt", "lib_ss", "lib_ff"}
        missing = required - set(family["views"])
        if missing:
            failures.append(f"{family['name']} missing views: {sorted(missing)}")
        for view_name, view in family["views"].items():
            sha = view.get("git_blob_sha1", "")
            if len(sha) != 40:
                failures.append(f"{family['name']} {view_name} lacks full blob SHA")

    if failures:
        for failure in failures:
            print(f"ERROR {failure}")
        return 1

    print(
        "PASS Rev-A physical contract: "
        f"{expected_total:.3f} mm^2 SRAM macros / {user_area:.1f} mm^2 user area "
        f"({fraction * 100:.1f}%), baseline={physical['baseline_clock_mhz']} MHz, "
        f"SRAM22={manifest['source']['commit']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
