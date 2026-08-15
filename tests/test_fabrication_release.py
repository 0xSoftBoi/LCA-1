# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import json
import unittest
from pathlib import Path

from tools.gen_fabrication_artifacts import generate
from tools.validate_fabrication import validate_contract


ROOT = Path(__file__).resolve().parents[1]


class FabricationReleaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.release = json.loads((ROOT / "fabrication/rev_a_release.json").read_text(encoding="utf-8"))
        cls.package = json.loads((ROOT / "fabrication/rev_a_package.json").read_text(encoding="utf-8"))
        cls.classified_rtl = {entry["path"] for entry in cls.release["rtl_disposition"]}

    def test_contract_semantics(self) -> None:
        self.assertEqual(validate_contract(self.release, self.package, self.classified_rtl), [])

    def test_generated_artifacts_are_current(self) -> None:
        for relative_path, expected in generate(self.package).items():
            self.assertEqual((ROOT / relative_path).read_text(encoding="utf-8"), expected)

    def test_physical_pin_map_has_no_aliases(self) -> None:
        pinout = self.package["qfn_pinout"]
        self.assertEqual(len(pinout), 65)
        self.assertEqual({row["pin"] for row in pinout}, {str(index) for index in range(1, 65)} | {"EP"})
        gpio_pins = [row["pin"] for row in pinout if row["name"].startswith("gpio[")]
        self.assertEqual(len(gpio_pins), len(set(gpio_pins)))

    def test_link_bus_is_complete(self) -> None:
        signal_map = {row["signal"]: row for row in self.package["logical_io"]}
        self.assertEqual([signal_map[f"host_d[{i}]"]["gpio"] for i in range(16)], list(range(16)))
        self.assertEqual([signal_map[f"host_addr[{i}]"]["gpio"] for i in range(8)], list(range(16, 24)))
        self.assertEqual(signal_map["host_clk"]["gpio"], 38)

    def test_tamper_and_unused_pins_fail_safe(self) -> None:
        signal_map = {row["signal"]: row for row in self.package["logical_io"]}
        self.assertIn("disconnected means tamper asserted", signal_map["tamper_n"]["safe_state"])
        for index in range(5):
            row = signal_map[f"reserved[{index}]"]
            self.assertEqual((row["dm"], row["oeb"], row["inp_dis"]), ("000", 1, 1))


if __name__ == "__main__":
    unittest.main()
