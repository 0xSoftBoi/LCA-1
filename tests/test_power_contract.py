# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import unittest

from model.power_contract import ActivitySample, PowerTrace


class PowerContractTests(unittest.TestCase):
    def test_integrates_measured_trace(self) -> None:
        trace = PowerTrace(
            source="board-instrument",
            hardware_id="synthetic-test-only",
            operation="authenticated_bridge",
            samples=[
                ActivitySample(0, "idle", 0, 100_000_000, measured_watts=2.0),
                ActivitySample(1_000_000_000, "kem", 1, 100_000_000, measured_watts=4.0),
                ActivitySample(2_000_000_000, "idle", 0, 100_000_000, measured_watts=2.0),
            ],
        )
        self.assertAlmostEqual(trace.integrate_joules(measured=True), 6.0)

    def test_refuses_missing_measurements(self) -> None:
        trace = PowerTrace(
            source="model",
            hardware_id="none",
            operation="test",
            samples=[
                ActivitySample(0, "idle", 0, 1),
                ActivitySample(1, "idle", 0, 1),
            ],
        )
        with self.assertRaises(ValueError):
            trace.integrate_joules(measured=True)

    def test_requires_monotonic_timestamps(self) -> None:
        trace = PowerTrace(
            source="model",
            hardware_id="none",
            operation="test",
            samples=[
                ActivitySample(5, "idle", 0, 1, estimated_watts=0),
                ActivitySample(5, "idle", 0, 1, estimated_watts=0),
            ],
        )
        with self.assertRaises(ValueError):
            trace.validate()


if __name__ == "__main__":
    unittest.main()
