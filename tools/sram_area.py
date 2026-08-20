#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""SRAM bank fit arithmetic for the LCA-1 Rev-A memory decision (T1).

This tool answers one question with sourced numbers: how much silicon area a
32 KiB (and 64 KiB) 32-bit-wide SRAM bank costs on SKY130, for each macro
family that is actually obtainable, and how that compares with the commercial
ChipFoundry macro the Rev-A release currently names as its baseline.

Standard library only, so it runs in the ordinary CI job before any PDK or
EDA tool is installed.

Provenance discipline
---------------------
Every dimension below is tagged with where it came from. The tool never mixes
the tags silently; ``--check`` re-parses each quoted LEF ``SIZE`` line and
fails if a recorded dimension disagrees with its own quoted provenance.

    lef_measured      Parsed from the ``SIZE x BY y ;`` line of the MACRO block
                      in the distributed .lef view. This is the physical macro
                      outline, not an estimate.
    paper_table       Quoted from a published table. No .lef/.gds view is
                      distributed for this macro, so it cannot be placed.
    vendor_datasheet  Quoted from a vendor product page. No view, no license,
                      and no independent measurement.
    computed          Derived here by arithmetic from the rows above.

Nothing in this file is a measurement of a hardening run. Bank areas are the
sum of macro outlines: real placement adds halos, routing channels, and the
wrapper's own standard cells. Pass ``--channel-x/--channel-y/--margin`` to get
an explicitly-labelled array-envelope ESTIMATE that includes those channels.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Optional

ROOT = Path(__file__).resolve().parents[1]

# OpenFrame user-project area, from fabrication/rev_a_release.json
# (route.shell.user_area_mm2). --check cross-verifies this against that file
# when it is present, so the constant cannot drift from the release contract.
OPENFRAME_USER_AREA_MM2 = 15.0

# Upstream sources, pinned to the exact commits read on 2026-08-15/16.
VLSIDA_REPO = "https://github.com/VLSIDA/sky130_sram_macros"
VLSIDA_COMMIT = "965df150c754fe2b3f93a0bd1f9883eb114279b2"
SRAM22_REPO = "https://github.com/rahulk29/sram22_sky130_macros"
SRAM22_COMMIT = "75cbe961e18ee00d5a6c73fa455505f0bcdf4c05"
ISCAS_2023 = "https://ieeexplore.ieee.org/document/10181379/"
CF_SRAM_PAGE = "https://chipfoundry.io/commercial-sram"
CF_SRAM_MACRO_PAGE = "https://chipfoundry.io/commercial-sram-macro"

# One project-scope license fee covers every instance of every ChipFoundry
# commercial SRAM macro, per CF_SRAM_PAGE ("$2500 per project ... You can
# implement as many instances of the above macros in a single ChipCreate
# project for the same price."), retrieved 2026-08-15.
CF_PROJECT_PRICE_USD = 2500


@dataclass(frozen=True)
class Macro:
    """One SRAM macro, with the provenance of its geometry attached."""

    key: str
    name: str
    words: int
    word_bits: int
    ports: str
    provenance: str
    source_url: str
    license: str
    obtainable: bool  # a placeable .lef + .gds view is actually distributed
    # Geometry: either an outline measured/quoted in microns, or a bare area.
    width_um: Optional[float] = None
    height_um: Optional[float] = None
    area_mm2_quoted: Optional[float] = None
    # Verbatim provenance strings.
    view_path: str = ""
    size_line: str = ""
    silicon: str = "none published"
    notes: str = ""

    @property
    def capacity_bytes(self) -> int:
        return self.words * self.word_bits // 8

    @property
    def area_um2(self) -> float:
        if self.width_um is not None and self.height_um is not None:
            return self.width_um * self.height_um
        assert self.area_mm2_quoted is not None
        return self.area_mm2_quoted * 1e6

    @property
    def area_mm2(self) -> float:
        return self.area_um2 / 1e6

    @property
    def mm2_per_kib(self) -> float:
        return self.area_mm2 / (self.capacity_bytes / 1024)


MACROS: tuple[Macro, ...] = (
    # ---------------------------------------------------------------- OpenRAM
    # Distributed by VLSIDA (upstream), mirrored by efabless and by
    # fossi-foundation (the repository open_pdks installs into
    # $PDK_ROOT/sky130A/libs.ref/sky130_sram_macros). All three trees carry the
    # same four macros; the 4 kB/8 kB/16 kB configs exist under configs/ but no
    # LEF or GDS for them is distributed anywhere in those trees.
    Macro(
        key="openram_2kbyte_32x512",
        name="sky130_sram_2kbyte_1rw1r_32x512_8",
        words=512,
        word_bits=32,
        ports="1RW+1R",
        provenance="lef_measured",
        source_url=f"{VLSIDA_REPO}/blob/{VLSIDA_COMMIT}"
        "/sky130_sram_2kbyte_1rw1r_32x512_8/sky130_sram_2kbyte_1rw1r_32x512_8.lef",
        license="Apache-2.0",
        obtainable=True,
        width_um=683.1,
        height_um=416.54,
        view_path="sky130_sram_2kbyte_1rw1r_32x512_8/sky130_sram_2kbyte_1rw1r_32x512_8.lef",
        # Verbatim line 10 of the .lef, inside `MACRO sky130_sram_2kbyte_1rw1r_32x512_8`:
        size_line="SIZE 683.1 BY 416.54 ;",
        silicon="taped out on the OpenRAM MPW2 test chip; no measured results "
        "published in the ISCAS 2023 paper",
        notes="largest 32-bit-word OpenRAM macro with a distributed view; "
        "pins on met4 top and bottom edges, vccd1/vssd1 rails on left/right",
    ),
    Macro(
        key="openram_1kbyte_32x256",
        name="sky130_sram_1kbyte_1rw1r_32x256_8",
        words=256,
        word_bits=32,
        ports="1RW+1R",
        provenance="lef_measured",
        source_url=f"{VLSIDA_REPO}/blob/{VLSIDA_COMMIT}"
        "/sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.lef",
        license="Apache-2.0",
        obtainable=True,
        width_um=479.78,
        height_um=397.5,
        view_path="sky130_sram_1kbyte_1rw1r_32x256_8/sky130_sram_1kbyte_1rw1r_32x256_8.lef",
        size_line="SIZE 479.78 BY 397.5 ;",
        silicon="this configuration (32-bit, 1 kbyte, dual-port) is the macro "
        f"measured in silicon on OR1 and reported at ISCAS 2023 ({ISCAS_2023})",
        notes="the only OpenRAM SKY130 macro with published silicon measurements",
    ),
    Macro(
        key="openram_1kbyte_8x1024",
        name="sky130_sram_1kbyte_1rw1r_8x1024_8",
        words=1024,
        word_bits=8,
        ports="1RW+1R",
        provenance="lef_measured",
        source_url=f"{VLSIDA_REPO}/blob/{VLSIDA_COMMIT}"
        "/sky130_sram_1kbyte_1rw1r_8x1024_8/sky130_sram_1kbyte_1rw1r_8x1024_8.lef",
        license="Apache-2.0",
        obtainable=True,
        width_um=455.3,
        height_um=446.46,
        view_path="sky130_sram_1kbyte_1rw1r_8x1024_8/sky130_sram_1kbyte_1rw1r_8x1024_8.lef",
        size_line="SIZE 455.3 BY 446.46 ;",
        silicon="taped out on the OpenRAM MPW2 test chip; no measured results "
        "published in the ISCAS 2023 paper",
        notes="8-bit word: a 32-bit bus needs four macros side by side",
    ),
    Macro(
        key="openram_legacy_1kbyte_32x256",
        name="sram_1rw1r_32_256_8_sky130",
        words=256,
        word_bits=32,
        ports="1RW+1R",
        provenance="lef_measured",
        source_url=f"{VLSIDA_REPO}/blob/{VLSIDA_COMMIT}"
        "/sram_1rw1r_32_256_8_sky130/sram_1rw1r_32_256_8_sky130.lef",
        license="Apache-2.0",
        obtainable=True,
        width_um=376.48,
        height_um=446.235,
        view_path="sram_1rw1r_32_256_8_sky130/sram_1rw1r_32_256_8_sky130.lef",
        size_line="SIZE 376.48 BY 446.235 ;",
        silicon="none published",
        notes="older naming/flow kept in the tree; ships multi-corner .lib "
        "files (FF/SS/TT, 1.7-1.9 V, 0-100 C) that the current macros lack, "
        "but its 24.8 MB detailed LEF is not an abstract view",
    ),
    Macro(
        key="openram_4kbyte_32x1024",
        name="sky130_sram_4kbyte_1rw1r_32x1024_8",
        words=1024,
        word_bits=32,
        ports="1RW+1R",
        provenance="paper_table",
        source_url=ISCAS_2023,
        license="Apache-2.0 (generator and configs; no view distributed)",
        obtainable=False,
        width_um=693.9,
        height_um=668.8,
        view_path="(no .lef or .gds distributed in any known tree)",
        # ISCAS 2023 Table I, "MEMORY CONFIGURATIONS TAPED-OUT ON THE MPW2 TEST
        # CHIP": width 693.9 um, height 668.8 um. Table I reproduces the .lef
        # SIZE values exactly for the three macros that do ship views, which is
        # why these two rows are treated as trustworthy geometry.
        size_line="ISCAS 2023 Table I: Width 693.9 um, Height 668.8 um",
        silicon="taped out on MPW2; no measured results published",
        notes="config exists at configs/sky130_sram_4kbyte_1rw1r_32x1024_8.py "
        "but the macro must be regenerated with OpenRAM to be usable",
    ),
    Macro(
        key="openram_8kbyte_32x2048",
        name="sky130_sram_8kbyte_1rw1r_32x2048_8",
        words=2048,
        word_bits=32,
        ports="1RW+1R",
        provenance="paper_table",
        source_url=ISCAS_2023,
        license="Apache-2.0 (generator and configs; no view distributed)",
        obtainable=False,
        width_um=1093.8,
        height_um=720.5,
        view_path="(no .lef or .gds distributed in any known tree)",
        size_line="ISCAS 2023 Table I: Width 1093.8 um, Height 720.5 um",
        silicon="taped out on MPW2; no measured results published",
        notes="the 8 kB config is commented out in the macro repository "
        "Makefile; regeneration required",
    ),
    # ----------------------------------------------------------------- SRAM22
    # A second free generator (UC Berkeley). Included because the OpenRAM tree
    # tops out at 2 kB per macro, and SRAM22 is the only other SKY130 macro set
    # found that distributes placeable views for larger arrays.
    Macro(
        key="sram22_2048x32",
        name="sram22_2048x32m8w8",
        words=2048,
        word_bits=32,
        ports="1RW",
        provenance="lef_measured",
        source_url=f"{SRAM22_REPO}/blob/{SRAM22_COMMIT}"
        "/sram22_2048x32m8w8/sram22_2048x32m8w8.lef",
        license="BSD-3-Clause",
        obtainable=True,
        width_um=674.480,
        height_um=781.920,
        view_path="sram22_2048x32m8w8/sram22_2048x32m8w8.lef",
        size_line="SIZE 674.480 BY 781.920 ;",
        silicon="repository README states this macro was taped out via "
        "Cadence's shuttle program and 'behaved correctly in silicon "
        "measurements when tested at VDD=1.8V and at a clock frequency of "
        "25 MHz'; no paper, no per-die data, no characterization released",
        notes="single-port only: a 1RW+1R access pattern needs arbitration in "
        "the wrapper; upstream says 'use at your own risk'",
    ),
    Macro(
        key="sram22_1024x32",
        name="sram22_1024x32m8w8",
        words=1024,
        word_bits=32,
        ports="1RW",
        provenance="lef_measured",
        source_url=f"{SRAM22_REPO}/blob/{SRAM22_COMMIT}"
        "/sram22_1024x32m8w8/sram22_1024x32m8w8.lef",
        license="BSD-3-Clause",
        obtainable=True,
        width_um=764.240,
        height_um=460.280,
        view_path="sram22_1024x32m8w8/sram22_1024x32m8w8.lef",
        size_line="SIZE 764.240 BY 460.280 ;",
        silicon="listed as taped out and correct at 1.8 V / 25 MHz in the "
        "repository README",
        notes="single-port",
    ),
    Macro(
        key="sram22_512x32",
        name="sram22_512x32m4w8",
        words=512,
        word_bits=32,
        ports="1RW",
        provenance="lef_measured",
        source_url=f"{SRAM22_REPO}/blob/{SRAM22_COMMIT}"
        "/sram22_512x32m4w8/sram22_512x32m4w8.lef",
        license="BSD-3-Clause",
        obtainable=True,
        width_um=443.280,
        height_um=448.720,
        view_path="sram22_512x32m4w8/sram22_512x32m4w8.lef",
        size_line="SIZE 443.280 BY 448.720 ;",
        silicon="listed as taped out and correct at 1.8 V / 25 MHz in the "
        "repository README",
        notes="single-port; direct size-for-size comparison against the "
        "OpenRAM 2 kB macro",
    ),
    # ----------------------------------------------------- ChipFoundry (paid)
    Macro(
        key="cf_sram_8192x32",
        name="CF_SRAM_8192x32",
        words=8192,
        word_bits=32,
        ports="Wishbone (port count not published)",
        provenance="vendor_datasheet",
        source_url=CF_SRAM_PAGE,
        license=f"commercial, ${CF_PROJECT_PRICE_USD} per project",
        obtainable=False,
        area_mm2_quoted=1.34,
        view_path="(views delivered through IPM after purchase; not inspected)",
        size_line=f"{CF_SRAM_PAGE} (retrieved 2026-08-15): 32KB, 1.34 mm2, "
        "Wishbone Bus, $2500 per project",
        silicon="not stated on the product page",
        notes="the Rev-A baseline in fabrication/rev_a_release.json; no "
        "dimensions, aspect ratio, port list, timing, or license text is "
        "public, so nothing here is independently verifiable",
    ),
    Macro(
        key="cf_sram_4096x32",
        name="CF_SRAM_4096x32",
        words=4096,
        word_bits=32,
        ports="Wishbone (port count not published)",
        provenance="vendor_datasheet",
        source_url=CF_SRAM_PAGE,
        license=f"commercial, ${CF_PROJECT_PRICE_USD} per project",
        obtainable=False,
        area_mm2_quoted=0.67,
        view_path="(views delivered through IPM after purchase; not inspected)",
        size_line=f"{CF_SRAM_PAGE} (retrieved 2026-08-15): 16KB, 0.67 mm2",
        silicon="not stated on the product page",
        notes="",
    ),
    Macro(
        key="cf_sram_1024x32",
        name="CF_SRAM_1024x32",
        words=1024,
        word_bits=32,
        ports="Wishbone (port count not published)",
        provenance="vendor_datasheet",
        source_url=CF_SRAM_PAGE,
        license=f"commercial, ${CF_PROJECT_PRICE_USD} per project",
        obtainable=False,
        area_mm2_quoted=0.165,
        view_path="(views delivered through IPM after purchase; not inspected)",
        size_line=f"{CF_SRAM_PAGE} (retrieved 2026-08-15): 4KB, 0.165 mm2",
        silicon="not stated on the product page",
        notes="vendor pages disagree: the catalog says 0.165 mm2 while "
        f"{CF_SRAM_MACRO_PAGE} gives 387.870 um x 303.315 um = 0.1176 mm2 for "
        "SRAM_1024x32. Both are vendor figures; neither was measured here",
    ),
)

MACRO_BY_KEY = {macro.key: macro for macro in MACROS}

# The macro the Rev-A release names as its memory baseline; every free option
# is reported relative to this one.
REFERENCE_KEY = "cf_sram_8192x32"

DEFAULT_TARGETS_BYTES = (32 * 1024, 64 * 1024)
DEFAULT_BUS_BITS = 32

SIZE_LINE_RE = re.compile(r"SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)\s*;")


@dataclass
class BankPlan:
    """A tiling of one macro into a target capacity at a target bus width."""

    macro: Macro
    target_bytes: int
    bus_bits: int
    macros_per_row: int
    rows: int
    channel_x_um: float = 0.0
    channel_y_um: float = 0.0
    margin_um: float = 0.0
    columns: int = 0
    envelope_w_um: float = 0.0
    envelope_h_um: float = 0.0
    warnings: list[str] = field(default_factory=list)

    @property
    def instances(self) -> int:
        return self.macros_per_row * self.rows

    @property
    def realized_bytes(self) -> int:
        return self.instances * self.macro.capacity_bytes

    @property
    def macro_area_mm2(self) -> float:
        return self.instances * self.macro.area_mm2

    @property
    def overprovision_bytes(self) -> int:
        return self.realized_bytes - self.target_bytes

    @property
    def envelope_mm2(self) -> Optional[float]:
        if not self.envelope_w_um or not self.envelope_h_um:
            return None
        return self.envelope_w_um * self.envelope_h_um / 1e6


def plan_bank(
    macro: Macro,
    target_bytes: int,
    bus_bits: int = DEFAULT_BUS_BITS,
    channel_x_um: float = 0.0,
    channel_y_um: float = 0.0,
    margin_um: float = 0.0,
) -> BankPlan:
    """Tile ``macro`` into ``target_bytes`` at ``bus_bits`` data width.

    Width first (macros side by side until the bus is covered), then depth
    (rows of that width until the capacity is reached). Both directions round
    up: partial macros do not exist.
    """
    if bus_bits % macro.word_bits and macro.word_bits % bus_bits:
        # Neither divides the other; the wrapper would need bit-slicing that
        # this simple model does not describe.
        raise ValueError(
            f"{macro.name}: {macro.word_bits}-bit word does not tile a "
            f"{bus_bits}-bit bus cleanly"
        )
    macros_per_row = max(1, math.ceil(bus_bits / macro.word_bits))
    bytes_per_row = macros_per_row * macro.capacity_bytes
    rows = math.ceil(target_bytes / bytes_per_row)
    plan = BankPlan(
        macro=macro,
        target_bytes=target_bytes,
        bus_bits=bus_bits,
        macros_per_row=macros_per_row,
        rows=rows,
        channel_x_um=channel_x_um,
        channel_y_um=channel_y_um,
        margin_um=margin_um,
    )
    if not macro.obtainable:
        plan.warnings.append(
            "no placeable view is distributed for this macro; the plan is "
            "arithmetic only"
        )
    if macro.provenance != "lef_measured":
        plan.warnings.append(
            f"geometry is {macro.provenance}, not measured from a LEF"
        )
    if channel_x_um or channel_y_um or margin_um:
        _add_envelope(plan, channel_x_um, channel_y_um, margin_um)
    return plan


def _add_envelope(
    plan: BankPlan, channel_x_um: float, channel_y_um: float, margin_um: float
) -> None:
    """Attach the most-square array envelope ESTIMATE to ``plan``.

    Chooses the column count whose bounding box aspect ratio is closest to 1.
    This is a floorplan sketch, not a placement result.
    """
    macro = plan.macro
    if macro.width_um is None or macro.height_um is None:
        plan.warnings.append(
            "no outline dimensions for this macro; envelope not computed"
        )
        return
    best: Optional[tuple[float, int, float, float]] = None
    for columns in range(1, plan.instances + 1):
        if plan.instances % columns:
            continue
        rows = plan.instances // columns
        width = (
            columns * macro.width_um
            + (columns - 1) * channel_x_um
            + 2 * margin_um
        )
        height = rows * macro.height_um + (rows - 1) * channel_y_um + 2 * margin_um
        aspect = max(width, height) / min(width, height)
        candidate = (aspect, columns, width, height)
        if best is None or candidate < best:
            best = candidate
    assert best is not None
    _, columns, width, height = best
    plan.columns = columns
    plan.envelope_w_um = width
    plan.envelope_h_um = height


def compare_to_reference(plan: BankPlan, reference: Macro) -> dict[str, Any]:
    """Compare a plan against the commercial reference macro."""
    ref_plan = plan_bank(reference, plan.target_bytes, plan.bus_bits)
    ref_area = ref_plan.macro_area_mm2
    return {
        "reference_macro": reference.name,
        "reference_instances": ref_plan.instances,
        "reference_area_mm2": round(ref_area, 6),
        "reference_area_provenance": reference.provenance,
        "area_ratio_vs_reference": round(plan.macro_area_mm2 / ref_area, 4),
        "extra_area_mm2": round(plan.macro_area_mm2 - ref_area, 6),
        "licence_cost_avoided_usd": (
            CF_PROJECT_PRICE_USD if plan.macro.license.startswith(("Apache", "BSD")) else 0
        ),
    }


def plan_to_dict(plan: BankPlan, reference: Macro) -> dict[str, Any]:
    macro = plan.macro
    record: dict[str, Any] = {
        "macro": macro.name,
        "key": macro.key,
        "license": macro.license,
        "obtainable_view": macro.obtainable,
        "geometry_provenance": macro.provenance,
        "geometry_source": macro.source_url,
        "geometry_quoted": macro.size_line,
        "macro_words": macro.words,
        "macro_word_bits": macro.word_bits,
        "macro_capacity_bytes": macro.capacity_bytes,
        "macro_area_mm2": round(macro.area_mm2, 6),
        "macro_mm2_per_kib": round(macro.mm2_per_kib, 6),
        "target_bytes": plan.target_bytes,
        "bus_bits": plan.bus_bits,
        "macros_per_row": plan.macros_per_row,
        "rows": plan.rows,
        "instances": plan.instances,
        "realized_bytes": plan.realized_bytes,
        "overprovision_bytes": plan.overprovision_bytes,
        "total_macro_area_mm2": round(plan.macro_area_mm2, 6),
        "total_macro_area_provenance": (
            "computed" if macro.provenance != "vendor_datasheet" else "computed_from_vendor_datasheet"
        ),
        "openframe_user_area_fraction": round(
            plan.macro_area_mm2 / OPENFRAME_USER_AREA_MM2, 4
        ),
        "warnings": list(plan.warnings),
    }
    envelope = plan.envelope_mm2
    if envelope is not None:
        record["array_envelope_estimate"] = {
            "note": "ESTIMATE: macro outlines plus routing channels and margin; "
            "not a placement result",
            "columns": plan.columns,
            "rows": plan.instances // plan.columns,
            "channel_x_um": plan.channel_x_um,
            "channel_y_um": plan.channel_y_um,
            "margin_um": plan.margin_um,
            "width_um": round(plan.envelope_w_um, 3),
            "height_um": round(plan.envelope_h_um, 3),
            "area_mm2": round(envelope, 6),
        }
    if macro.key != reference.key:
        record["comparison"] = compare_to_reference(plan, reference)
    return record


def build_report(
    targets: tuple[int, ...] = DEFAULT_TARGETS_BYTES,
    bus_bits: int = DEFAULT_BUS_BITS,
    channel_x_um: float = 0.0,
    channel_y_um: float = 0.0,
    margin_um: float = 0.0,
) -> dict[str, Any]:
    reference = MACRO_BY_KEY[REFERENCE_KEY]
    report: dict[str, Any] = {
        "tool": "tools/sram_area.py",
        "purpose": "Rev-A T1 memory_area_timing: 32/64 KiB SRAM bank fit on SKY130",
        "provenance_legend": {
            "lef_measured": "parsed from the MACRO SIZE line of a distributed .lef",
            "paper_table": "quoted from a published table; no view distributed",
            "vendor_datasheet": "quoted from a vendor product page; not verifiable",
            "computed": "derived here from the rows above",
        },
        "openframe_user_area_mm2": OPENFRAME_USER_AREA_MM2,
        "reference_macro": reference.name,
        "sources": {
            "openram_macros": f"{VLSIDA_REPO} @ {VLSIDA_COMMIT}",
            "sram22_macros": f"{SRAM22_REPO} @ {SRAM22_COMMIT}",
            "openram_silicon_paper": ISCAS_2023,
            "chipfoundry_catalog": CF_SRAM_PAGE,
            "chipfoundry_macro_page": CF_SRAM_MACRO_PAGE,
        },
        "macros": [
            {
                "key": macro.key,
                "name": macro.name,
                "words": macro.words,
                "word_bits": macro.word_bits,
                "ports": macro.ports,
                "capacity_bytes": macro.capacity_bytes,
                "width_um": macro.width_um,
                "height_um": macro.height_um,
                "area_mm2": round(macro.area_mm2, 6),
                "mm2_per_kib": round(macro.mm2_per_kib, 6),
                "provenance": macro.provenance,
                "quoted": macro.size_line,
                "source": macro.source_url,
                "view_path": macro.view_path,
                "license": macro.license,
                "obtainable_view": macro.obtainable,
                "silicon": macro.silicon,
                "notes": macro.notes,
            }
            for macro in MACROS
        ],
        "plans": {},
    }
    for target in targets:
        plans = []
        for macro in MACROS:
            try:
                plan = plan_bank(
                    macro,
                    target,
                    bus_bits,
                    channel_x_um,
                    channel_y_um,
                    margin_um,
                )
            except ValueError as error:
                plans.append({"macro": macro.name, "skipped": str(error)})
                continue
            plans.append(plan_to_dict(plan, reference))
        plans.sort(key=lambda item: item.get("total_macro_area_mm2", math.inf))
        report["plans"][f"{target // 1024}KiB"] = plans
    return report


# --------------------------------------------------------------------- checks


def check() -> list[str]:
    """Re-derive every recorded number from its own quoted provenance."""
    errors: list[str] = []

    for macro in MACROS:
        if not macro.source_url:
            errors.append(f"{macro.name}: missing source_url")
        if not macro.license:
            errors.append(f"{macro.name}: missing license")
        if not macro.size_line:
            errors.append(f"{macro.name}: missing quoted provenance line")
        if macro.provenance not in {
            "lef_measured",
            "paper_table",
            "vendor_datasheet",
        }:
            errors.append(f"{macro.name}: unknown provenance {macro.provenance!r}")
        if macro.capacity_bytes * 8 != macro.words * macro.word_bits:
            errors.append(f"{macro.name}: capacity does not match words x word_bits")
        if macro.words <= 0 or macro.word_bits <= 0:
            errors.append(f"{macro.name}: non-positive geometry")

        if macro.provenance == "lef_measured":
            if not macro.view_path.endswith(".lef"):
                errors.append(f"{macro.name}: lef_measured without a .lef view path")
            match = SIZE_LINE_RE.search(macro.size_line)
            if match is None:
                errors.append(
                    f"{macro.name}: quoted line is not a LEF SIZE line: "
                    f"{macro.size_line!r}"
                )
            else:
                width, height = float(match.group(1)), float(match.group(2))
                if (width, height) != (macro.width_um, macro.height_um):
                    errors.append(
                        f"{macro.name}: recorded {macro.width_um} x "
                        f"{macro.height_um} disagrees with quoted SIZE "
                        f"{width} x {height}"
                    )
        if macro.provenance == "vendor_datasheet" and macro.area_mm2_quoted is None:
            errors.append(f"{macro.name}: vendor row without a quoted area")
        if macro.provenance == "vendor_datasheet" and macro.obtainable:
            errors.append(
                f"{macro.name}: vendor macro marked obtainable, but no view has "
                "been inspected"
            )

    keys = [macro.key for macro in MACROS]
    if len(keys) != len(set(keys)):
        errors.append("duplicate macro keys")
    if REFERENCE_KEY not in MACRO_BY_KEY:
        errors.append(f"reference macro {REFERENCE_KEY} is not in the table")

    # Bank arithmetic: each plan must cover the target, and must be minimal.
    for macro in MACROS:
        for target in DEFAULT_TARGETS_BYTES:
            try:
                plan = plan_bank(macro, target)
            except ValueError:
                continue
            if plan.realized_bytes < target:
                errors.append(f"{macro.name}: {target}B plan is short")
            if plan.rows > 1:
                smaller = (plan.rows - 1) * plan.macros_per_row * macro.capacity_bytes
                if smaller >= target:
                    errors.append(f"{macro.name}: {target}B plan is not minimal")
            if plan.macros_per_row * macro.word_bits < DEFAULT_BUS_BITS:
                errors.append(f"{macro.name}: plan does not cover the data bus")

    # The OpenFrame budget must match the release contract, when it is present.
    release = ROOT / "fabrication" / "rev_a_release.json"
    if release.is_file():
        try:
            contract = json.loads(release.read_text(encoding="utf-8"))
            contract_area = contract["route"]["shell"]["user_area_mm2"]
        except (ValueError, KeyError) as error:  # pragma: no cover - defensive
            errors.append(f"cannot read user_area_mm2 from {release}: {error}")
        else:
            if float(contract_area) != OPENFRAME_USER_AREA_MM2:
                errors.append(
                    "OPENFRAME_USER_AREA_MM2 "
                    f"({OPENFRAME_USER_AREA_MM2}) disagrees with "
                    f"{release.name} route.shell.user_area_mm2 ({contract_area})"
                )
    return errors


# --------------------------------------------------------------------- output

_TAG = {
    "lef_measured": "[LEF]",
    "paper_table": "[PAPER]",
    "vendor_datasheet": "[VENDOR]",
}


def _print_text(report: dict[str, Any]) -> None:
    print("LCA-1 Rev-A SRAM bank fit (T1 memory_area_timing)")
    print("=" * 78)
    print()
    print("Provenance tags:")
    print("  [LEF]    measured from the MACRO SIZE line of a distributed .lef")
    print("  [PAPER]  quoted from a published table; no placeable view exists")
    print("  [VENDOR] quoted from a vendor page; not independently verifiable")
    print("  every total below is COMPUTED from the tagged rows, and is a sum")
    print("  of macro outlines only - no halos, channels, or wrapper logic")
    print()

    print("Macro inventory")
    print("-" * 78)
    print(
        f"{'tag':9s}{'macro':37s}{'cap':>5s} {'area mm2':>9s} "
        f"{'mm2/KiB':>8s}  view"
    )
    for macro in report["macros"]:
        tag = _TAG[macro["provenance"]]
        view = "yes" if macro["obtainable_view"] else "NO VIEW"
        print(
            f"{tag:9s}{macro['name']:37s}"
            f"{macro['capacity_bytes'] // 1024:4d}K "
            f"{macro['area_mm2']:9.4f} {macro['mm2_per_kib']:8.4f}  {view}"
        )
    print()

    for target, plans in report["plans"].items():
        print(f"{target} bank at {DEFAULT_BUS_BITS}-bit data width")
        print("-" * 78)
        for plan in plans:
            if "skipped" in plan:
                print(f"  {plan['macro']:38s} skipped: {plan['skipped']}")
                continue
            comparison = plan.get("comparison")
            ratio = (
                f"x{comparison['area_ratio_vs_reference']:.2f} vs "
                f"{comparison['reference_macro']}"
                if comparison
                else "(reference)"
            )
            marker = "  [NO VIEW]" if not plan["obtainable_view"] else ""
            print(
                f"  {plan['macro']:37s}{plan['instances']:3d} x macro = "
                f"{plan['total_macro_area_mm2']:7.4f} mm2  {ratio}{marker}"
            )
            print(
                f"      {plan['license']:44s}"
                f"{plan['openframe_user_area_fraction'] * 100:5.1f}% of the "
                f"{report['openframe_user_area_mm2']} mm2 user area"
            )
            envelope = plan.get("array_envelope_estimate")
            if envelope:
                print(
                    f"      ESTIMATE envelope {envelope['columns']}x"
                    f"{envelope['rows']}: {envelope['width_um']:.1f} x "
                    f"{envelope['height_um']:.1f} um = "
                    f"{envelope['area_mm2']:.4f} mm2"
                )
        print()

    print("Cost")
    print("-" * 78)
    print(
        f"  [VENDOR] ChipFoundry commercial SRAM: ${CF_PROJECT_PRICE_USD} per "
        "project, unlimited instances"
    )
    print("  [LEF]    OpenRAM sky130_sram_macros: Apache-2.0, $0")
    print("  [LEF]    SRAM22 sky130 macros:       BSD-3-Clause, $0")
    print()
    print("Sources")
    print("-" * 78)
    for name, url in report["sources"].items():
        print(f"  {name:24s} {url}")
    print()
    print(
        "This tool reports geometry only. Timing closure, DRC/LVS in context, "
        "and IR/EM\nremain unmeasured; see docs/SRAM_DECISION.md."
    )


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Compute 32/64 KiB SKY130 SRAM bank areas from LEF-measured "
        "macro geometry and compare against the commercial baseline.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="validate provenance and bank arithmetic; exit non-zero on failure",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON")
    parser.add_argument(
        "--bus-bits",
        type=int,
        default=DEFAULT_BUS_BITS,
        help="data bus width in bits (default: 32)",
    )
    parser.add_argument(
        "--target-kib",
        type=int,
        action="append",
        help="capacity target in KiB; repeatable (default: 32 and 64)",
    )
    parser.add_argument(
        "--channel-x",
        type=float,
        default=0.0,
        metavar="UM",
        help="horizontal routing channel between macros, microns (ESTIMATE)",
    )
    parser.add_argument(
        "--channel-y",
        type=float,
        default=0.0,
        metavar="UM",
        help="vertical routing channel between macro rows, microns (ESTIMATE)",
    )
    parser.add_argument(
        "--margin",
        type=float,
        default=0.0,
        metavar="UM",
        help="margin from the array edge to the core boundary (ESTIMATE)",
    )
    args = parser.parse_args(argv)

    if args.check:
        errors = check()
        if errors:
            print("sram_area: FAIL", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            return 1
        print(f"sram_area: OK ({len(MACROS)} macro records checked)")
        return 0

    targets = tuple(
        kib * 1024 for kib in (args.target_kib or [kib for kib in (32, 64)])
    )
    report = build_report(
        targets=targets,
        bus_bits=args.bus_bits,
        channel_x_um=args.channel_x,
        channel_y_um=args.channel_y,
        margin_um=args.margin,
    )
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        _print_text(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
