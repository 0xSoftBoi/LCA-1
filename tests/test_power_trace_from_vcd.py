# SPDX-License-Identifier: Apache-2.0
"""Tests for the VCD activity-trace generator.

Everything here is hermetic: the VCD is a hand-written synthetic dump with
known-answer toggle counts, and no simulator or git probe is invoked.
"""

from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path

from tools.power_trace_from_vcd import (
    SchemaError,
    VcdError,
    build_parser,
    compute_cycle_activity,
    generate,
    hamming_distance,
    load_schema,
    main,
    parse_vcd,
    resolve_signal,
    select_signals,
    trace_payload,
    validate_against_schema,
    StateRules,
)

KEM_Q = 3329          # 000000000000110100000001, popcount 4
DSA_Q = 8380417       # 011111111110000000000001, popcount 11, HD(KEM,DSA) = 13

# Five rising clock edges at 5/15/25/35/45 ns with a 10 ns period.
#
# The dump deliberately exercises: two scopes, an aliased identifier (`%` is
# declared as both `tb.acc_mirror` and `tb.dut.acc`), a `$var parameter` that
# cannot toggle, scalar and vector value changes, an uninitialised (`x`)
# register, short vector literals that need left-extension, and a `$comment`
# in the value section.
SYNTHETIC_VCD = f"""$date
\tTue Jan 1 00:00:00 2030
$end
$version
\tsynthetic-test
$end
$timescale
\t1ns
$end
$scope module tb $end
$var reg 1 ! clk $end
$var reg 1 " rst_n $end
$var wire 4 % acc_mirror [3:0] $end
$scope module dut $end
$var wire 1 ! clk $end
$var reg 1 # busy $end
$var reg 24 $ modulus [23:0] $end
$var reg 4 % acc [3:0] $end
$var parameter 32 & WORD_BITS $end
$upscope $end
$upscope $end
$enddefinitions $end
$comment parameters $end
#0
$dumpvars
0!
0"
0#
b0 $
bx %
$end
#5
1!
b0 %
#10
0!
1"
#15
1!
1#
b{KEM_Q:b} $
b0101 %
#20
0!
#25
1!
b1010 %
#30
0!
#35
1!
b{DSA_Q:b} $
#40
0!
#45
1!
0#
b0 %
"""

# Expected weighted toggle counts, cycle by cycle:
#   edge 1 @5ns  : acc xxxx -> 0000                        = 4
#   edge 2 @15ns : busy 0->1, modulus 0 -> 3329, acc 0000 -> 0101
#                  = 1 + 4 + 2                             = 7
#   edge 3 @25ns : acc 0101 -> 1010                        = 4
#   edge 4 @35ns : modulus 3329 -> 8380417                 = 13
#   edge 5 @45ns : busy 1->0, acc 1010 -> 0000             = 1 + 2 = 3
EXPECTED_TOGGLES = [4.0, 7.0, 4.0, 13.0, 3.0]
# State is the state held *during* the cycle that ends at the edge.
EXPECTED_STATES = ["zeroize", "idle", "kem", "kem", "dsa"]


def write_vcd(directory: Path, text: str = SYNTHETIC_VCD) -> Path:
    path = directory / "synthetic.vcd"
    path.write_text(text, encoding="utf-8")
    return path


class VcdParserTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.vcd = parse_vcd(write_vcd(self.tmp))

    def test_parses_header_metadata(self) -> None:
        self.assertEqual(self.vcd.version, "synthetic-test")
        self.assertEqual(self.vcd.date, "Tue Jan 1 00:00:00 2030")
        self.assertEqual(self.vcd.timescale_text, "1ns")
        self.assertEqual(self.vcd.timescale_seconds, Fraction(1, 10**9))

    def test_builds_hierarchical_paths_and_strips_bit_ranges(self) -> None:
        paths = {var.path for var in self.vcd.variables}
        self.assertEqual(
            paths,
            {
                "tb.clk",
                "tb.rst_n",
                "tb.acc_mirror",
                "tb.dut.clk",
                "tb.dut.busy",
                "tb.dut.modulus",
                "tb.dut.acc",
                "tb.dut.WORD_BITS",
            },
        )
        widths = {var.path: var.width for var in self.vcd.variables}
        self.assertEqual(widths["tb.dut.modulus"], 24)
        self.assertEqual(widths["tb.dut.acc"], 4)

    def test_left_extends_short_vector_literals(self) -> None:
        by_time = {block.time: block.changes for block in self.vcd.time_blocks}
        self.assertEqual(by_time[0]["$"], "0" * 24)
        self.assertEqual(by_time[0]["%"], "xxxx")
        self.assertEqual(by_time[15]["$"], format(KEM_Q, "024b"))
        self.assertEqual(by_time[5]["%"], "0000")

    def test_groups_changes_by_time_stamp(self) -> None:
        times = [block.time for block in self.vcd.time_blocks]
        self.assertEqual(times, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45])
        self.assertEqual(self.vcd.time_blocks[3].changes["#"], "1")

    def test_rejects_malformed_input(self) -> None:
        broken = self.tmp / "broken.vcd"
        broken.write_text("$timescale 1ns $end\n", encoding="utf-8")
        with self.assertRaises(VcdError):
            parse_vcd(broken)

    def test_resolves_signals_by_name_and_path(self) -> None:
        self.assertEqual(resolve_signal(self.vcd, "busy"), "#")
        self.assertEqual(resolve_signal(self.vcd, "tb.dut.modulus"), "$")
        self.assertIsNone(resolve_signal(self.vcd, ""))
        with self.assertRaises(VcdError):
            resolve_signal(self.vcd, "not_a_signal")


class HammingTest(unittest.TestCase):
    def test_counts_differing_bit_positions(self) -> None:
        self.assertEqual(hamming_distance("0000", "0000"), 0)
        self.assertEqual(hamming_distance("0101", "1010"), 4)
        self.assertEqual(hamming_distance("1111", "1110"), 1)

    def test_treats_unknown_symbols_as_ordinary_values(self) -> None:
        self.assertEqual(hamming_distance("xxxx", "0000"), 4)
        self.assertEqual(hamming_distance("xxxx", "xxxx"), 0)
        self.assertEqual(hamming_distance("x0z1", "x0z1"), 0)
        self.assertEqual(hamming_distance("x0z1", "0011"), 2)

    def test_extends_unequal_widths_before_comparing(self) -> None:
        self.assertEqual(hamming_distance("1", "0001"), 0)
        self.assertEqual(hamming_distance("1", "0011"), 1)

    def test_matches_known_modulus_transition(self) -> None:
        self.assertEqual(
            hamming_distance(format(KEM_Q, "024b"), format(DSA_Q, "024b")), 13
        )


class SignalSelectionTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.vcd = parse_vcd(write_vcd(self.tmp))

    def test_drops_parameters_clock_and_alias_duplicates(self) -> None:
        tracked, skipped = select_signals(self.vcd, exclude_idents={"!"})
        paths = [signal.path for signal in tracked]
        # `%` is declared twice (tb.acc_mirror and tb.dut.acc); one physical net
        # must be counted once.
        self.assertEqual(paths, ["tb.acc_mirror", "tb.dut.busy", "tb.dut.modulus", "tb.rst_n"])
        self.assertIn("tb.dut.WORD_BITS", skipped)
        self.assertIn("tb.clk", skipped)

    def test_count_aliases_opt_in(self) -> None:
        tracked, _ = select_signals(self.vcd, exclude_idents={"!"}, count_aliases=True)
        self.assertEqual(len(tracked), 5)

    def test_scope_filter(self) -> None:
        tracked, _ = select_signals(self.vcd, scopes=["tb.dut"], exclude_idents={"!"})
        self.assertEqual(
            [signal.path for signal in tracked],
            ["tb.dut.acc", "tb.dut.busy", "tb.dut.modulus"],
        )

    def test_glob_exclusion(self) -> None:
        tracked, skipped = select_signals(
            self.vcd, scopes=["tb.dut"], excludes=["*.modulus"], exclude_idents={"!"}
        )
        self.assertNotIn("tb.dut.modulus", [signal.path for signal in tracked])
        self.assertIn("tb.dut.modulus", skipped)


class CycleActivityTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.vcd = parse_vcd(write_vcd(self.tmp))
        self.rules = StateRules(
            reset_ident=resolve_signal(self.vcd, "rst_n"),
            busy_ident=resolve_signal(self.vcd, "busy"),
            modulus_ident=resolve_signal(self.vcd, "modulus"),
        )
        self.tracked, _ = select_signals(self.vcd, scopes=["tb.dut"], exclude_idents={"!"})

    def test_known_answer_toggle_counts(self) -> None:
        samples = compute_cycle_activity(self.vcd, self.tracked, "!", self.rules)
        self.assertEqual([sample.timestamp_ns for sample in samples], [5, 15, 25, 35, 45])
        self.assertEqual([sample.toggles for sample in samples], EXPECTED_TOGGLES)

    def test_activity_state_labelling(self) -> None:
        samples = compute_cycle_activity(self.vcd, self.tracked, "!", self.rules)
        self.assertEqual([sample.state for sample in samples], EXPECTED_STATES)
        self.assertEqual([sample.active_lanes for sample in samples], [0, 0, 1, 1, 1])

    def test_weights_scale_the_proxy(self) -> None:
        tracked, _ = select_signals(
            self.vcd,
            scopes=["tb.dut"],
            weights=[("tb.dut.modulus", 0.5)],
            exclude_idents={"!"},
        )
        samples = compute_cycle_activity(self.vcd, tracked, "!", self.rules)
        # Only the two modulus transitions are halved: 7 -> 5.0 and 13 -> 6.5.
        self.assertEqual(
            [sample.toggles for sample in samples], [4.0, 5.0, 4.0, 6.5, 3.0]
        )

    def test_requires_at_least_two_clock_edges(self) -> None:
        short = write_vcd(
            self.tmp,
            SYNTHETIC_VCD.split("#10")[0].replace("#5\n1!\nb0 %\n", "#5\n1!\n"),
        )
        vcd = parse_vcd(short)
        tracked, _ = select_signals(vcd, scopes=["tb.dut"], exclude_idents={"!"})
        with self.assertRaises(VcdError):
            compute_cycle_activity(vcd, tracked, "!", self.rules)


class SchemaConformanceTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.vcd_path = write_vcd(self.tmp)
        self.schema = load_schema()

    def _generate(self, extra: list[str] | None = None):
        args = build_parser().parse_args(
            [
                "--vcd",
                str(self.vcd_path),
                "--out",
                str(self.tmp / "trace.json"),
                "--scope",
                "tb.dut",
                "--no-tool-probe",
                *(extra or []),
            ]
        )
        return generate(args)

    def test_emitted_trace_conforms_to_the_published_schema(self) -> None:
        _, payload = self._generate()
        validate_against_schema(payload, self.schema)
        self.assertEqual(payload["schema_version"], "1.0")
        self.assertEqual(payload["source"], "simulator")
        self.assertEqual(len(payload["samples"]), len(EXPECTED_TOGGLES))
        self.assertEqual(
            [sample["state"] for sample in payload["samples"]], EXPECTED_STATES
        )

    def test_reports_no_watts(self) -> None:
        _, payload = self._generate()
        for sample in payload["samples"]:
            self.assertIsNone(sample["estimated_watts"])
            self.assertIsNone(sample["measured_watts"])
        proxy = payload["metadata"]["activity_proxy"]
        self.assertFalse(proxy["is_power_measurement"])
        self.assertFalse(proxy["is_power_estimate"])
        self.assertIn("PROXY ONLY", proxy["warning"])
        self.assertEqual(payload["metadata"]["watts_basis"], "neither estimated nor measured")

    def test_metadata_carries_required_contract_fields(self) -> None:
        _, payload = self._generate(["--metadata", "a=7", "--metadata", "b=9"])
        metadata = payload["metadata"]
        for key in (
            "workload",
            "clock_hz",
            "sample_interval_ns",
            "instrument_bandwidth_hz",
            "voltage_v",
            "ambient_c",
            "cooling",
            "idle_power_treatment",
            "repetitions",
            "source_commit",
            "tool_versions",
            "vcd",
        ):
            self.assertIn(key, metadata)
        self.assertEqual(metadata["clock_hz"], 100_000_000)
        self.assertEqual(metadata["sample_interval_ns"], 10)
        self.assertEqual(metadata["operation_parameters"], {"a": "7", "b": "9"})
        self.assertEqual(metadata["activity_proxy"]["per_cycle"], EXPECTED_TOGGLES)
        self.assertEqual(
            metadata["vcd"]["unique_identifiers"], 6
        )  # ! " # $ % &

    def test_samples_carry_the_derived_clock(self) -> None:
        _, payload = self._generate()
        self.assertTrue(all(sample["clock_hz"] == 100_000_000 for sample in payload["samples"]))
        self.assertEqual(
            [sample["timestamp_ns"] for sample in payload["samples"]], [5, 15, 25, 35, 45]
        )

    def test_validator_rejects_non_conforming_payloads(self) -> None:
        trace, payload = self._generate()
        self.assertEqual(trace_payload(trace), payload)

        bad_state = json.loads(json.dumps(payload))
        bad_state["samples"][0]["state"] = "sleeping"
        with self.assertRaises(SchemaError):
            validate_against_schema(bad_state, self.schema)

        extra_field = json.loads(json.dumps(payload))
        extra_field["samples"][0]["toggle_count"] = 4
        with self.assertRaises(SchemaError):
            validate_against_schema(extra_field, self.schema)

        missing = json.loads(json.dumps(payload))
        del missing["hardware_id"]
        with self.assertRaises(SchemaError):
            validate_against_schema(missing, self.schema)

        too_short = json.loads(json.dumps(payload))
        too_short["samples"] = too_short["samples"][:1]
        with self.assertRaises(SchemaError):
            validate_against_schema(too_short, self.schema)

        negative = json.loads(json.dumps(payload))
        negative["samples"][0]["active_lanes"] = -1
        with self.assertRaises(SchemaError):
            validate_against_schema(negative, self.schema)


class CommandLineTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.vcd_path = write_vcd(self.tmp)

    def test_writes_a_valid_trace_file(self) -> None:
        out = self.tmp / "nested" / "trace.json"
        status = main(
            [
                "--vcd",
                str(self.vcd_path),
                "--out",
                str(out),
                "--scope",
                "tb.dut",
                "--no-tool-probe",
            ]
        )
        self.assertEqual(status, 0)
        payload = json.loads(out.read_text(encoding="utf-8"))
        validate_against_schema(payload, load_schema())

    def test_reports_unknown_clock_as_an_error(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            status = main(
                [
                    "--vcd",
                    str(self.vcd_path),
                    "--out",
                    str(self.tmp / "unused.json"),
                    "--clock",
                    "nope",
                    "--no-tool-probe",
                ]
            )
        self.assertEqual(status, 2)
        self.assertIn("not found in VCD", captured.getvalue())


if __name__ == "__main__":
    unittest.main()
