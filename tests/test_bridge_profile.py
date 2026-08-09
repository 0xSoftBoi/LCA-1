from __future__ import annotations

import unittest

from bench.bridge_profile import PrimitiveCounts, PrimitiveMeasurement, summarize


class BridgeProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.measurements = {
            "kem_encaps": PrimitiveMeasurement(latency_ns=10, energy_uj=1),
            "kem_decaps": PrimitiveMeasurement(latency_ns=20, energy_uj=2),
            "dsa_sign": PrimitiveMeasurement(latency_ns=30, energy_uj=3),
            "dsa_verify": PrimitiveMeasurement(latency_ns=40, energy_uj=4),
        }

    def test_authenticated_path(self) -> None:
        result = summarize(PrimitiveCounts.authenticated(), self.measurements)
        self.assertEqual(result["primitive_latency_sum_ns"], 170)
        self.assertEqual(result["primitive_energy_sum_uj"], 17)

    def test_batch_scales_counts(self) -> None:
        result = summarize(PrimitiveCounts.minimal(), self.measurements, transfers=8)
        self.assertEqual(result["primitive_latency_sum_ns"], 800)
        self.assertEqual(result["breakdown"]["dsa_sign"]["count"], 8)

    def test_incomplete_energy_is_not_reported(self) -> None:
        measurements = dict(self.measurements)
        measurements["dsa_verify"] = PrimitiveMeasurement(latency_ns=40)
        result = summarize(PrimitiveCounts.authenticated(), measurements)
        self.assertIsNone(result["primitive_energy_sum_uj"])

    def test_requires_exact_measurement_set(self) -> None:
        measurements = dict(self.measurements)
        del measurements["kem_encaps"]
        with self.assertRaises(ValueError):
            summarize(PrimitiveCounts.authenticated(), measurements)


if __name__ == "__main__":
    unittest.main()
