# SPDX-License-Identifier: Apache-2.0
"""Arithmetic and provenance gates for tools/sram_area.py.

These tests do not check that the recorded dimensions are the *true* macro
dimensions - only the upstream .lef files can do that, and the quoted SIZE
line in each record is the audit trail for it. What they do check is that no
number in the table drifts away from the provenance quoted beside it, that
every record says where it came from, and that the bank arithmetic is exact.
"""

from __future__ import annotations

import io
import json
import re
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from tools import sram_area


ROOT = Path(__file__).resolve().parents[1]
ALLOWED_PROVENANCE = {"lef_measured", "paper_table", "vendor_datasheet"}


class ProvenanceTest(unittest.TestCase):
    def test_self_check_passes(self) -> None:
        self.assertEqual(sram_area.check(), [])

    def test_every_macro_declares_its_source(self) -> None:
        for macro in sram_area.MACROS:
            with self.subTest(macro=macro.name):
                self.assertTrue(macro.source_url.startswith("https://"))
                self.assertTrue(macro.license)
                self.assertTrue(macro.size_line)
                self.assertTrue(macro.view_path)
                self.assertTrue(macro.silicon)
                self.assertIn(macro.provenance, ALLOWED_PROVENANCE)

    def test_lef_measured_records_match_their_quoted_size_line(self) -> None:
        """Re-parse the quoted LEF line independently of sram_area.check()."""
        pattern = re.compile(r"^SIZE (\d+(?:\.\d+)?) BY (\d+(?:\.\d+)?) ;$")
        measured = [m for m in sram_area.MACROS if m.provenance == "lef_measured"]
        self.assertGreaterEqual(len(measured), 4)
        for macro in measured:
            with self.subTest(macro=macro.name):
                match = pattern.match(macro.size_line)
                self.assertIsNotNone(
                    match, f"{macro.name}: {macro.size_line!r} is not a LEF SIZE line"
                )
                assert match is not None
                self.assertEqual(float(match.group(1)), macro.width_um)
                self.assertEqual(float(match.group(2)), macro.height_um)
                self.assertTrue(macro.view_path.endswith(".lef"))
                self.assertTrue(macro.obtainable)

    def test_unobtainable_macros_are_marked(self) -> None:
        """Macros with no distributed view must never look placeable."""
        for macro in sram_area.MACROS:
            if macro.provenance in {"paper_table", "vendor_datasheet"}:
                with self.subTest(macro=macro.name):
                    self.assertFalse(macro.obtainable)
                    plan = sram_area.plan_bank(macro, 32 * 1024)
                    self.assertTrue(plan.warnings)

    def test_vendor_rows_carry_a_quoted_area_and_price(self) -> None:
        vendor = [m for m in sram_area.MACROS if m.provenance == "vendor_datasheet"]
        self.assertTrue(vendor)
        for macro in vendor:
            with self.subTest(macro=macro.name):
                self.assertIsNotNone(macro.area_mm2_quoted)
                self.assertIn(str(sram_area.CF_PROJECT_PRICE_USD), macro.license)

    def test_openframe_budget_matches_release_contract(self) -> None:
        release = json.loads(
            (ROOT / "fabrication" / "rev_a_release.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            float(release["route"]["shell"]["user_area_mm2"]),
            sram_area.OPENFRAME_USER_AREA_MM2,
        )

    def test_reference_macro_is_the_release_baseline(self) -> None:
        release = json.loads(
            (ROOT / "fabrication" / "rev_a_release.json").read_text(encoding="utf-8")
        )
        reference = sram_area.MACRO_BY_KEY[sram_area.REFERENCE_KEY]
        self.assertEqual(release["memory"]["baseline"]["macro"], reference.name)
        self.assertEqual(
            float(release["memory"]["baseline"]["area_mm2_each_vendor_published"]),
            reference.area_mm2,
        )


class MacroGeometryTest(unittest.TestCase):
    def test_capacity_follows_from_words_and_word_bits(self) -> None:
        for macro in sram_area.MACROS:
            with self.subTest(macro=macro.name):
                self.assertEqual(
                    macro.capacity_bytes * 8, macro.words * macro.word_bits
                )

    def test_area_is_the_product_of_the_outline(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"]
        self.assertAlmostEqual(macro.area_um2, 683.1 * 416.54, places=6)
        self.assertAlmostEqual(macro.area_mm2, 0.28453847, places=8)
        self.assertAlmostEqual(macro.mm2_per_kib, 0.28453847 / 2, places=8)

    def test_vendor_area_is_used_verbatim(self) -> None:
        macro = sram_area.MACRO_BY_KEY["cf_sram_8192x32"]
        self.assertIsNone(macro.width_um)
        self.assertEqual(macro.area_mm2, 1.34)
        self.assertEqual(macro.capacity_bytes, 32 * 1024)


class BankPlanTest(unittest.TestCase):
    def test_32kib_from_the_largest_distributed_openram_macro(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"]
        plan = sram_area.plan_bank(macro, 32 * 1024)
        self.assertEqual(plan.macros_per_row, 1)
        self.assertEqual(plan.rows, 16)
        self.assertEqual(plan.instances, 16)
        self.assertEqual(plan.realized_bytes, 32 * 1024)
        self.assertEqual(plan.overprovision_bytes, 0)
        self.assertAlmostEqual(plan.macro_area_mm2, 4.5526155, places=6)

    def test_64kib_doubles_the_32kib_plan(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"]
        small = sram_area.plan_bank(macro, 32 * 1024)
        large = sram_area.plan_bank(macro, 64 * 1024)
        self.assertEqual(large.instances, 2 * small.instances)
        self.assertAlmostEqual(large.macro_area_mm2, 2 * small.macro_area_mm2, places=9)

    def test_narrow_word_macro_tiles_across_the_bus(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_1kbyte_8x1024"]
        plan = sram_area.plan_bank(macro, 32 * 1024, bus_bits=32)
        self.assertEqual(plan.macros_per_row, 4)
        self.assertEqual(plan.rows, 8)
        self.assertEqual(plan.instances, 32)
        self.assertEqual(plan.realized_bytes, 32 * 1024)

    def test_every_plan_covers_the_target_and_is_minimal(self) -> None:
        for macro in sram_area.MACROS:
            for target in (32 * 1024, 64 * 1024):
                with self.subTest(macro=macro.name, target=target):
                    plan = sram_area.plan_bank(macro, target)
                    self.assertGreaterEqual(plan.realized_bytes, target)
                    self.assertGreaterEqual(
                        plan.macros_per_row * macro.word_bits, plan.bus_bits
                    )
                    if plan.rows > 1:
                        one_row_less = (
                            (plan.rows - 1)
                            * plan.macros_per_row
                            * macro.capacity_bytes
                        )
                        self.assertLess(one_row_less, target)

    def test_bus_width_that_does_not_tile_is_rejected(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"]
        with self.assertRaises(ValueError):
            sram_area.plan_bank(macro, 32 * 1024, bus_bits=24)

    def test_comparison_against_the_commercial_reference(self) -> None:
        reference = sram_area.MACRO_BY_KEY[sram_area.REFERENCE_KEY]
        plan = sram_area.plan_bank(
            sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"], 32 * 1024
        )
        comparison = sram_area.compare_to_reference(plan, reference)
        self.assertEqual(comparison["reference_instances"], 1)
        self.assertEqual(comparison["reference_area_mm2"], 1.34)
        self.assertAlmostEqual(comparison["area_ratio_vs_reference"], 3.3975, places=4)
        self.assertAlmostEqual(comparison["extra_area_mm2"], 3.212616, places=5)
        self.assertEqual(
            comparison["licence_cost_avoided_usd"], sram_area.CF_PROJECT_PRICE_USD
        )

    def test_envelope_is_only_produced_when_asked_and_is_labelled(self) -> None:
        macro = sram_area.MACRO_BY_KEY["openram_2kbyte_32x512"]
        bare = sram_area.plan_bank(macro, 32 * 1024)
        self.assertIsNone(bare.envelope_mm2)

        plan = sram_area.plan_bank(
            macro,
            32 * 1024,
            channel_x_um=40,
            channel_y_um=120,
            margin_um=100,
        )
        self.assertEqual(plan.columns, 4)
        # 4 x 683.1 + 3 x 40 + 2 x 100, and 4 x 416.54 + 3 x 120 + 2 x 100.
        self.assertAlmostEqual(plan.envelope_w_um, 3052.4, places=3)
        self.assertAlmostEqual(plan.envelope_h_um, 2226.16, places=3)
        envelope = plan.envelope_mm2
        assert envelope is not None
        self.assertGreater(envelope, plan.macro_area_mm2)

        record = sram_area.plan_to_dict(
            plan, sram_area.MACRO_BY_KEY[sram_area.REFERENCE_KEY]
        )
        self.assertIn("ESTIMATE", record["array_envelope_estimate"]["note"])


class ReportTest(unittest.TestCase):
    def test_report_separates_measured_from_quoted(self) -> None:
        report = sram_area.build_report()
        self.assertIn("lef_measured", report["provenance_legend"])
        self.assertIn("vendor_datasheet", report["provenance_legend"])
        for row in report["macros"]:
            self.assertIn(row["provenance"], ALLOWED_PROVENANCE)
            self.assertTrue(row["quoted"])
            self.assertTrue(row["source"])

    def test_plans_are_sorted_by_total_area(self) -> None:
        report = sram_area.build_report()
        for target, plans in report["plans"].items():
            with self.subTest(target=target):
                areas = [p["total_macro_area_mm2"] for p in plans if "skipped" not in p]
                self.assertEqual(areas, sorted(areas))

    def test_report_is_json_serialisable(self) -> None:
        report = sram_area.build_report()
        round_tripped = json.loads(json.dumps(report))
        self.assertEqual(round_tripped["reference_macro"], "CF_SRAM_8192x32")
        self.assertEqual(
            round_tripped["openframe_user_area_mm2"],
            sram_area.OPENFRAME_USER_AREA_MM2,
        )


class HardeningConfigTest(unittest.TestCase):
    """Keep hardening/lca_sram_fit in step with the measured LEF geometry."""

    PROJECT = ROOT / "hardening" / "lca_sram_fit"
    MACRO_KEY = "openram_2kbyte_32x512"

    @classmethod
    def setUpClass(cls) -> None:
        cls.config = json.loads(
            (cls.PROJECT / "config.json").read_text(encoding="utf-8")
        )
        cls.alt_config = json.loads(
            (cls.PROJECT / "config_extra_lefs.json").read_text(encoding="utf-8")
        )
        cls.macro = sram_area.MACRO_BY_KEY[cls.MACRO_KEY]

    def _instances(self) -> dict[str, dict]:
        macros = self.config["MACROS"]
        self.assertEqual(list(macros), [self.macro.name])
        return macros[self.macro.name]["instances"]

    def test_referenced_files_exist(self) -> None:
        for relative in ("lca_sram_fit.sv", "sky130_sram_2kbyte_1rw1r_32x512_8.vh"):
            self.assertTrue((self.PROJECT / relative).is_file(), relative)
        self.assertEqual(self.config["VERILOG_FILES"], ["dir::lca_sram_fit.sv"])
        entry = self.config["MACROS"][self.macro.name]
        self.assertEqual(entry["vh"], ["dir::sky130_sram_2kbyte_1rw1r_32x512_8.vh"])
        for key in ("gds", "lef"):
            self.assertTrue(entry[key][0].startswith("pdk_dir::"))

    def test_instance_count_matches_the_32kib_plan(self) -> None:
        plan = sram_area.plan_bank(self.macro, 32 * 1024)
        instances = self._instances()
        self.assertEqual(len(instances), plan.instances)
        self.assertEqual(
            sorted(instances), sorted(f"u_bank[{i}]" for i in range(plan.instances))
        )

    def test_macros_sit_inside_the_core_area_and_do_not_overlap(self) -> None:
        width, height = self.macro.width_um, self.macro.height_um
        assert width is not None and height is not None
        core_x0, core_y0, core_x1, core_y1 = self.config["CORE_AREA"]
        boxes = []
        for name, instance in self._instances().items():
            x, y = instance["location"]
            self.assertEqual(instance["orientation"], "N")
            with self.subTest(instance=name):
                self.assertGreaterEqual(x, core_x0)
                self.assertGreaterEqual(y, core_y0)
                self.assertLessEqual(x + width, core_x1)
                self.assertLessEqual(y + height, core_y1)
            boxes.append((x, y, x + width, y + height))
        for i, first in enumerate(boxes):
            for second in boxes[i + 1 :]:
                overlap = (
                    first[0] < second[2]
                    and second[0] < first[2]
                    and first[1] < second[3]
                    and second[1] < first[3]
                )
                self.assertFalse(overlap, f"{first} overlaps {second}")

    def test_core_area_fits_inside_the_die_area(self) -> None:
        die = self.config["DIE_AREA"]
        core = self.config["CORE_AREA"]
        self.assertLessEqual(die[0], core[0])
        self.assertLessEqual(die[1], core[1])
        self.assertGreaterEqual(die[2], core[2])
        self.assertGreaterEqual(die[3], core[3])
        die_mm2 = (die[2] - die[0]) * (die[3] - die[1]) / 1e6
        plan = sram_area.plan_bank(self.macro, 32 * 1024)
        self.assertGreater(die_mm2, plan.macro_area_mm2)
        self.assertLess(die_mm2, sram_area.OPENFRAME_USER_AREA_MM2)

    def test_pdn_hooks_cover_every_macro_instance(self) -> None:
        hooks = self.config["PDN_MACRO_CONNECTIONS"]
        self.assertTrue(hooks)
        for name in self._instances():
            matched = any(
                re.fullmatch(hook.split(" ", 1)[0], name) for hook in hooks
            )
            self.assertTrue(matched, f"no PDN hook matches {name}")
        for hook in hooks:
            fields = hook.split()
            self.assertEqual(len(fields), 5, hook)
            self.assertEqual(fields[3:], ["vccd1", "vssd1"])

    def test_alternate_config_wires_the_same_views_without_macros(self) -> None:
        self.assertNotIn("MACROS", self.alt_config)
        for key in ("EXTRA_LEFS", "EXTRA_GDS_FILES", "EXTRA_LIBS"):
            self.assertTrue(self.alt_config[key])
        entry = self.config["MACROS"][self.macro.name]
        self.assertEqual(self.alt_config["EXTRA_LEFS"], entry["lef"])
        self.assertEqual(self.alt_config["EXTRA_GDS_FILES"], entry["gds"])
        for key in ("DESIGN_NAME", "CLOCK_PORT", "CLOCK_PERIOD", "DIE_AREA"):
            self.assertEqual(self.alt_config[key], self.config[key])

    def test_wrapper_rtl_matches_the_bank_organisation(self) -> None:
        rtl = (self.PROJECT / "lca_sram_fit.sv").read_text(encoding="utf-8")
        plan = sram_area.plan_bank(self.macro, 32 * 1024)
        self.assertIn(f"parameter integer BANKS          = {plan.instances}", rtl)
        self.assertIn(self.macro.name + " u_bank", rtl)
        # 512 words per macro means a 9-bit intra-bank address.
        self.assertIn("BANK_ADDR_BITS = 9", rtl)
        self.assertEqual(self.macro.words, 1 << 9)


class CommandLineTest(unittest.TestCase):
    def test_check_mode_exits_zero(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            status = sram_area.main(["--check"])
        self.assertEqual(status, 0)
        self.assertIn("OK", buffer.getvalue())

    def test_json_mode_emits_parseable_json(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            status = sram_area.main(["--json", "--target-kib", "32"])
        self.assertEqual(status, 0)
        payload = json.loads(buffer.getvalue())
        self.assertEqual(list(payload["plans"]), ["32KiB"])

    def test_text_mode_tags_every_provenance_class(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            status = sram_area.main([])
        self.assertEqual(status, 0)
        text = buffer.getvalue()
        for tag in ("[LEF]", "[PAPER]", "[VENDOR]"):
            self.assertIn(tag, text)
        self.assertIn("SRAM_DECISION.md", text)


if __name__ == "__main__":
    unittest.main()
