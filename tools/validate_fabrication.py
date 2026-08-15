#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Semantic validation for the LCA-1 Rev-A fabrication release.

This intentionally uses only the Python standard library so it can run before
the PDK/toolchain is installed and in the repository's ordinary CI job.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[1]
RELEASE_PATH = Path("fabrication/rev_a_release.json")
PACKAGE_PATH = Path("fabrication/rev_a_package.json")


class ContractError(Exception):
    """Raised when one or more release invariants fail."""


def _load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ContractError(f"{path}: top-level JSON value must be an object")
    return value


def _duplicate_values(values: Iterable[Any]) -> list[Any]:
    seen: set[Any] = set()
    duplicates: set[Any] = set()
    for value in values:
        if value in seen:
            duplicates.add(value)
        seen.add(value)
    return sorted(duplicates, key=str)


def _expect(errors: list[str], condition: bool, message: str) -> None:
    if not condition:
        errors.append(message)


def _parse_iso_date(errors: list[str], value: Any, label: str) -> date | None:
    try:
        return date.fromisoformat(value)
    except (TypeError, ValueError):
        errors.append(f"{label} must be an ISO-8601 date, got {value!r}")
        return None


def discover_rtl(repo_root: Path) -> set[str]:
    rtl_root = repo_root / "rtl"
    if not rtl_root.is_dir():
        raise ContractError(f"RTL tree not found at {rtl_root}")
    return {
        path.relative_to(repo_root).as_posix()
        for path in rtl_root.iterdir()
        if path.is_file() and path.suffix in {".sv", ".svh"}
    }


def validate_contract(
    release: dict[str, Any],
    package: dict[str, Any],
    discovered_rtl: set[str] | None,
) -> list[str]:
    errors: list[str] = []

    _expect(errors, release.get("schema_version") == 1, "release schema_version must be 1")
    _expect(errors, package.get("schema_version") == 1, "package schema_version must be 1")
    _expect(
        errors,
        release.get("release_id") == package.get("release_id") == "LCA1-S0-REV-A",
        "release_id must match LCA1-S0-REV-A in both manifests",
    )
    _parse_iso_date(errors, release.get("as_of"), "release.as_of")
    _parse_iso_date(errors, package.get("as_of"), "package.as_of")

    route = release.get("route", {})
    shell = route.get("shell", {})
    _expect(errors, route.get("process") == "SKY130", "Rev-A process must be SKY130")
    _expect(errors, shell.get("name") == "OpenFrame", "Rev-A shell must be OpenFrame")
    _expect(errors, shell.get("gpio_count") == 44, "OpenFrame GPIO count must be 44")
    _expect(errors, shell.get("management_cpu") is False, "OpenFrame route must not claim a management CPU")
    _expect(errors, shell.get("top_module") == "openframe_project_wrapper", "OpenFrame top-module name drifted")
    _expect(
        errors,
        isinstance(shell.get("commit"), str) and re.fullmatch(r"[0-9a-f]{40}", shell["commit"]) is not None,
        "OpenFrame source must be pinned to a 40-character commit",
    )
    _expect(
        errors,
        shell.get("commit") == package.get("source_shell", {}).get("commit"),
        "release and package manifests must pin the same OpenFrame commit",
    )

    schedule = route.get("schedule", {})
    schedule_fields = [
        "commitment_date",
        "tapeout_date",
        "mask_release_date",
        "lot_start_date",
        "wafer_complete_date",
        "packaging_start_date",
        "board_start_date",
        "delivery_date",
    ]
    parsed_schedule = [_parse_iso_date(errors, schedule.get(name), f"schedule.{name}") for name in schedule_fields]
    if all(parsed_schedule):
        _expect(errors, parsed_schedule == sorted(parsed_schedule), "fabrication schedule dates must be monotonic")
    _expect(
        errors,
        schedule.get("status") == "planning_snapshot_not_reservation",
        "schedule must not imply a reservation before commercial authorization",
    )

    commercial = route.get("commercial_snapshot", {})
    _expect(errors, commercial.get("reservation_status") == "not_authorized", "reservation must remain unauthorized")
    _expect(errors, commercial.get("contract_status") == "not_executed", "contract must remain not executed")
    _expect(errors, commercial.get("included_qfn_parts") == 100, "published package quantity must be 100")

    boundary = release.get("product_boundary", {})
    excluded = "\n".join(boundary.get("excluded_functions", [])).lower()
    for forbidden in ("picorv32", "whole-message", "tee", "ai inference"):
        _expect(errors, forbidden in excluded, f"product exclusions must explicitly cover {forbidden!r}")
    _expect(
        errors,
        boundary.get("maximum_retained_external_object_bytes") == 0,
        "Rev-A must not retain complete externally supplied objects",
    )
    _expect(errors, boundary.get("full_algorithm_commands_supported") is False, "Rev-A must not claim full algorithms")

    dispositions = release.get("rtl_disposition", [])
    disposition_paths = [entry.get("path") for entry in dispositions]
    _expect(errors, not _duplicate_values(disposition_paths), "rtl_disposition contains duplicate paths")
    allowed_dispositions = {"retain", "modify", "replace", "remove"}
    for entry in dispositions:
        _expect(errors, entry.get("disposition") in allowed_dispositions, f"invalid disposition for {entry.get('path')}")
        if entry.get("disposition") in {"replace", "remove"}:
            _expect(errors, entry.get("rev_a_netlist") is False, f"{entry.get('path')} cannot be in the netlist when removed/replaced")
    disposition_set = set(disposition_paths)
    if discovered_rtl is not None:
        _expect(
            errors,
            disposition_set == discovered_rtl,
            "rtl_disposition must classify every and only current rtl/*.sv and rtl/*.svh file; "
            f"missing={sorted(discovered_rtl - disposition_set)}, stale={sorted(disposition_set - discovered_rtl)}",
        )

    memory = release.get("memory", {})
    baseline = memory.get("baseline", {})
    experiment = memory.get("experiment", {})
    _expect(errors, memory.get("whole_message_buffer_forbidden") is True, "whole-message SRAM use must be forbidden")
    _expect(errors, baseline.get("logical_capacity_bytes") == 32768, "baseline SRAM must be exactly 32 KiB")
    _expect(errors, baseline.get("instances") == 1, "baseline SRAM must use one selected macro")
    _expect(errors, experiment.get("logical_capacity_bytes") == 65536, "experiment SRAM must be exactly 64 KiB")
    _expect(errors, experiment.get("instances") == 2, "64-KiB experiment must use two selected macros")
    _expect(errors, baseline.get("macro") == experiment.get("macro"), "baseline and experiment must use the same macro family")
    zeroize = memory.get("zeroize", {})
    for key in ("power_on_scrub_required", "full_capacity_scrub_on_tamper", "full_capacity_scrub_on_host_zeroize", "ready_blocked_until_scrub_complete"):
        _expect(errors, zeroize.get(key) is True, f"memory.zeroize.{key} must be true")

    interface = release.get("shell_interface", {})
    _expect(errors, interface.get("clock_domains") == 1, "Rev-A must have one functional clock domain")
    _expect(errors, interface.get("data_width_bits") == 16, "LCA-LINK data width must be 16")
    _expect(errors, interface.get("address_width_bits") == 8, "LCA-LINK address width must be 8")
    _expect(errors, interface.get("maximum_outstanding_reads") == 1, "LCA-LINK must allow only one outstanding read")
    _expect(errors, "GPIO38" in interface.get("clock_source", ""), "clock source must name GPIO38")
    csr_addresses = [row.get("address") for row in interface.get("csr_halfwords", [])]
    command_values = [row.get("value") for row in interface.get("commands", [])]
    error_values = [row.get("value") for row in interface.get("error_codes", [])]
    _expect(errors, not _duplicate_values(csr_addresses), "CSR addresses must be unique")
    _expect(errors, not _duplicate_values(command_values), "command values must be unique")
    _expect(errors, not _duplicate_values(error_values), "error values must be unique")
    reset_contract = interface.get("reset_abort_zeroize", {})
    for key in ("power_on_behavior", "abort_behavior", "tamper_behavior", "illegal_request_behavior", "zeroize_completion"):
        _expect(errors, len(reset_contract.get(key, "")) >= 30, f"reset/abort/zeroize contract missing {key}")

    gates = release.get("release_gates", [])
    gate_ids = [gate.get("id") for gate in gates]
    _expect(errors, not _duplicate_values(gate_ids), "release gate IDs must be unique")
    _expect(errors, gate_ids == [f"T{i}" for i in range(8)], "release gates must be ordered T0 through T7")
    _expect(errors, gates[0].get("status") == "ready_for_independent_review", "T0 must remain review-gated")
    _expect(errors, gates[-1].get("status") == "blocked", "first-silicon gate cannot pass before silicon exists")

    sources = release.get("sources", [])
    for source in sources:
        _expect(errors, str(source.get("url", "")).startswith("https://"), f"source URL is not HTTPS: {source!r}")
        _parse_iso_date(errors, source.get("retrieved"), f"source {source.get('title')!r} retrieved")
    required_source_fragments = ("chipfoundry.io/faqs", "openframe_user_project/tree/", "skywater-pdk.readthedocs.io")
    source_urls = "\n".join(source.get("url", "") for source in sources)
    for fragment in required_source_fragments:
        _expect(errors, fragment in source_urls, f"missing primary source containing {fragment}")

    package_meta = package.get("package", {})
    _expect(errors, package_meta.get("family") == "QFN", "package family must be QFN")
    _expect(errors, package_meta.get("pin_count") == 64, "package pin count must be 64")
    _expect(errors, package_meta.get("body_mm") == [9.0, 9.0], "package body must be recorded as 9 mm x 9 mm")
    _expect(errors, package_meta.get("pitch_mm") == 0.5, "package pitch must be 0.5 mm")
    _expect(errors, package_meta.get("exposed_paddle") == "VSS", "exposed paddle must be VSS")
    _expect(errors, len(package_meta.get("source_errata", [])) >= 1, "datasheet pin conflict must remain recorded")

    pinout = package.get("qfn_pinout", [])
    pin_names = [pin.get("pin") for pin in pinout]
    expected_pins = {str(number) for number in range(1, 65)} | {"EP"}
    _expect(errors, set(pin_names) == expected_pins, "qfn_pinout must cover pins 1-64 and EP exactly")
    _expect(errors, not _duplicate_values(pin_names), "qfn_pinout contains duplicate physical pins")
    pin_by_name = {pin.get("name"): pin for pin in pinout if str(pin.get("name", "")).startswith("gpio[")}
    expected_gpio_names = {f"gpio[{number}]" for number in range(44)}
    _expect(errors, set(pin_by_name) == expected_gpio_names, "QFN pinout must map every GPIO0-43 exactly once")
    _expect(errors, any(pin.get("pin") == "21" and pin.get("name") == "resetb" for pin in pinout), "QFN pin 21 must be resetb")
    _expect(errors, any(pin.get("pin") == "38" and pin.get("name") == "vssa1" for pin in pinout), "Figure-2 correction requires pin 38=vssa1")
    _expect(errors, any(pin.get("pin") == "31" and pin.get("name") == "gpio[0]" for pin in pinout), "Figure-2 correction requires pin 31=gpio[0]")

    logical = package.get("logical_io", [])
    gpios = [entry.get("gpio") for entry in logical]
    signals = [entry.get("signal") for entry in logical]
    _expect(errors, set(gpios) == set(range(44)), "logical_io must cover GPIO0-43 exactly")
    _expect(errors, not _duplicate_values(gpios), "logical_io contains duplicate GPIO indices")
    _expect(errors, not _duplicate_values(signals), "logical_io contains duplicate signal names")
    physical_pin_by_gpio = {
        int(pin["name"][5:-1]): int(pin["pin"])
        for pin in pinout
        if re.fullmatch(r"gpio\[[0-9]+\]", str(pin.get("name")))
    }
    for entry in logical:
        gpio = entry.get("gpio")
        _expect(errors, entry.get("qfn_pin") == physical_pin_by_gpio.get(gpio), f"GPIO{gpio} logical/physical pin mismatch")
        direction = entry.get("direction")
        if direction == "input":
            _expect(errors, entry.get("dm") == "001" and entry.get("oeb") == 1 and entry.get("inp_dis") == 0, f"GPIO{gpio} input pad mode is unsafe")
        elif direction == "output":
            _expect(errors, entry.get("dm") == "110" and entry.get("oeb") == 0 and entry.get("inp_dis") == 1, f"GPIO{gpio} output pad mode is unsafe")
        elif direction == "bidirectional":
            _expect(errors, entry.get("dm") == "110" and isinstance(entry.get("oeb"), str) and entry.get("inp_dis") == 0, f"GPIO{gpio} bidirectional pad mode is unsafe")
        elif direction == "disabled":
            _expect(errors, entry.get("dm") == "000" and entry.get("oeb") == 1 and entry.get("inp_dis") == 1, f"GPIO{gpio} unused pad must be disabled")
        else:
            errors.append(f"GPIO{gpio} has unknown direction {direction!r}")

    expected_signals = {
        *(f"host_d[{index}]" for index in range(16)),
        *(f"host_addr[{index}]" for index in range(8)),
        "req_valid", "req_ready", "req_write", "req_last",
        "rsp_valid", "rsp_ready", "rsp_last", "irq", "tamper_n",
        "zeroize_req", "busy", "fault", "zeroize_busy", "selftest_fail", "host_clk",
        *(f"reserved[{index}]" for index in range(5)),
    }
    _expect(errors, set(signals) == expected_signals, "logical_io signal set does not match LCA-LINK-16")
    signal_map = {entry.get("signal"): entry for entry in logical}
    _expect(errors, signal_map.get("host_clk", {}).get("gpio") == 38, "host_clk must be GPIO38")
    _expect(errors, signal_map.get("tamper_n", {}).get("safe_state", "").startswith("external pull-down"), "tamper_n must fail safe when disconnected")
    _expect(errors, not any("test_mode" in signal for signal in signals), "Rev-A must not expose a test-mode pin")

    tests = package.get("ate_tests", [])
    test_ids = [test.get("id") for test in tests]
    _expect(errors, not _duplicate_values(test_ids), "ATE test IDs must be unique")
    for required_test in ("PKG-001", "PWR-001", "IF-001", "MEM-001", "KAT-KEC", "KAT-KEM", "KAT-DSA", "SEC-ZERO", "IF-BP", "CHAR-VF", "CHAR-PWR"):
        _expect(errors, required_test in test_ids, f"ATE plan missing {required_test}")

    blockers = package.get("freeze_blockers", [])
    _expect(errors, len(blockers) >= 8, "package freeze blockers are incomplete")
    if package.get("package_status") == "frozen":
        _expect(errors, not blockers, "frozen package cannot retain unresolved freeze blockers")
        _expect(errors, commercial.get("contract_status") == "executed", "frozen package requires executed commercial terms")

    return errors


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    parser.add_argument(
        "--skip-tree-check",
        action="store_true",
        help="Validate manifest semantics without scanning rtl/. Intended only for disconnected artifact development.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = args.repo_root.resolve()
    try:
        release = _load_json(repo_root / RELEASE_PATH)
        package = _load_json(repo_root / PACKAGE_PATH)
        rtl = None if args.skip_tree_check else discover_rtl(repo_root)
        errors = validate_contract(release, package, rtl)
    except (ContractError, OSError, json.JSONDecodeError) as exc:
        print(f"fabrication contract invalid: {exc}", file=sys.stderr)
        return 1

    if errors:
        print("fabrication contract invalid:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    tree_status = "skipped" if rtl is None else f"{len(rtl)} files"
    print(
        "fabrication contract valid: "
        f"release={release['release_id']} rtl={tree_status} "
        f"qfn_pins={len(package['qfn_pinout'])} gpio={len(package['logical_io'])} "
        f"ate_tests={len(package['ate_tests'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
