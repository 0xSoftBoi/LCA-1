# SPDX-License-Identifier: Apache-2.0
"""Tests for the fixed-vs-random leakage assessment.

Known-answer cases only: the statistics are cross-checked against the standard
library's ``statistics`` module and against hand-constructed distributions.
"""

from __future__ import annotations

import contextlib
import io
import json
import math
import random
import statistics
import tempfile
import unittest
from pathlib import Path

from tools.tvla import (
    DEFAULT_THRESHOLD,
    TvlaError,
    Welford,
    assess,
    expand_inputs,
    load_series,
    main,
    report_payload,
    summarise,
    welch_t,
)


def write_trace(path: Path, series: list[float]) -> Path:
    """Write the minimal trace shape the assessor reads."""
    payload = {
        "schema_version": "1.0",
        "source": "simulator",
        "hardware_id": "unit-test",
        "operation": "modmul",
        "metadata": {"activity_proxy": {"per_cycle": series}},
        "samples": [],
    }
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def write_set(directory: Path, name: str, traces: list[list[float]]) -> Path:
    target = directory / name
    target.mkdir(parents=True, exist_ok=True)
    for index, series in enumerate(traces):
        write_trace(target / f"{index:04d}.json", series)
    return target


class WelfordTest(unittest.TestCase):
    def test_matches_the_standard_library(self) -> None:
        rng = random.Random(7)
        values = [rng.gauss(100.0, 15.0) for _ in range(500)]
        accumulator = Welford()
        for value in values:
            accumulator.update(value)
        self.assertEqual(accumulator.count, len(values))
        self.assertAlmostEqual(accumulator.mean, statistics.fmean(values), places=9)
        self.assertAlmostEqual(accumulator.variance, statistics.variance(values), places=6)

    def test_is_stable_for_large_offsets(self) -> None:
        """A naive sum-of-squares estimator loses all precision here."""
        offset = 1e9
        accumulator = Welford()
        for value in (offset + 4, offset + 7, offset + 13, offset + 16):
            accumulator.update(value)
        self.assertAlmostEqual(accumulator.mean, offset + 10.0, places=6)
        self.assertAlmostEqual(accumulator.variance, 30.0, places=6)

    def test_variance_is_zero_below_two_samples(self) -> None:
        accumulator = Welford()
        self.assertEqual(accumulator.variance, 0.0)
        accumulator.update(3.0)
        self.assertEqual(accumulator.variance, 0.0)


class WelchTest(unittest.TestCase):
    @staticmethod
    def _fill(values: list[float]) -> Welford:
        accumulator = Welford()
        for value in values:
            accumulator.update(value)
        return accumulator

    def test_known_answer_against_the_textbook_formula(self) -> None:
        left = [12.0, 15.0, 11.0, 14.0, 13.0, 16.0]
        right = [22.0, 25.0, 19.0, 24.0, 21.0, 20.0]
        expected = (statistics.fmean(left) - statistics.fmean(right)) / math.sqrt(
            statistics.variance(left) / len(left) + statistics.variance(right) / len(right)
        )
        value, degenerate = welch_t(self._fill(left), self._fill(right))
        self.assertFalse(degenerate)
        self.assertAlmostEqual(value, expected, places=10)

    def test_identical_constant_sets_give_zero(self) -> None:
        value, degenerate = welch_t(self._fill([5.0] * 4), self._fill([5.0] * 4))
        self.assertEqual(value, 0.0)
        self.assertFalse(degenerate)

    def test_deterministic_difference_is_flagged_not_clipped(self) -> None:
        value, degenerate = welch_t(self._fill([5.0] * 4), self._fill([9.0] * 4))
        self.assertIsNone(value)
        self.assertTrue(degenerate)

    def test_requires_two_traces_per_set(self) -> None:
        with self.assertRaises(TvlaError):
            welch_t(self._fill([1.0]), self._fill([1.0, 2.0]))


class AssessmentTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_identical_distributions_stay_below_threshold(self) -> None:
        rng = random.Random(11)
        traces_a = [[rng.gauss(50.0, 5.0) for _ in range(20)] for _ in range(120)]
        traces_b = [[rng.gauss(50.0, 5.0) for _ in range(20)] for _ in range(120)]
        set_a = write_set(self.tmp, "a", traces_a)
        set_b = write_set(self.tmp, "b", traces_b)

        result = assess(sorted(set_a.glob("*.json")), sorted(set_b.glob("*.json")))
        self.assertEqual(len(result.points), 20)
        self.assertLess(result.max_abs_t, DEFAULT_THRESHOLD)
        self.assertEqual(result.exceeding, [])
        self.assertFalse(result.leaking)
        self.assertTrue(result.verdict().startswith("NO LEAKAGE DETECTED"))
        self.assertIn("not evidence of side-channel resistance", result.verdict())

    def test_separated_distributions_produce_large_t(self) -> None:
        rng = random.Random(13)
        traces_a = [[rng.gauss(50.0, 2.0) for _ in range(8)] for _ in range(60)]
        traces_b = [[rng.gauss(80.0, 2.0) for _ in range(8)] for _ in range(60)]
        set_a = write_set(self.tmp, "fixed", traces_a)
        set_b = write_set(self.tmp, "random", traces_b)

        result = assess(sorted(set_a.glob("*.json")), sorted(set_b.glob("*.json")))
        self.assertGreater(result.max_abs_t, 50.0)
        self.assertEqual(len(result.exceeding), 8)
        self.assertTrue(result.leaking)
        self.assertTrue(result.verdict().startswith("LEAKAGE DETECTED"))
        self.assertIn("8/8 sample points", result.verdict())

    def test_zero_variance_difference_is_reported_as_infinite(self) -> None:
        set_a = write_set(self.tmp, "const_a", [[3.0, 5.0]] * 10)
        set_b = write_set(self.tmp, "const_b", [[3.0, 9.0]] * 10)
        result = assess(sorted(set_a.glob("*.json")), sorted(set_b.glob("*.json")))
        self.assertEqual(result.points[0].t, 0.0)
        self.assertIsNone(result.points[1].t)
        self.assertTrue(result.points[1].degenerate)
        self.assertEqual(result.max_abs_t, math.inf)
        self.assertTrue(result.leaking)
        self.assertIn("infinite", result.verdict())

    def test_mismatched_lengths_need_explicit_truncation(self) -> None:
        set_a = write_set(self.tmp, "long", [[1.0, 2.0, 3.0]] * 4)
        set_b = write_set(self.tmp, "short", [[1.0, 2.0]] * 4)
        long_paths = sorted(set_a.glob("*.json"))
        short_paths = sorted(set_b.glob("*.json"))
        with self.assertRaises(TvlaError):
            assess(long_paths, short_paths)
        result = assess(long_paths, short_paths, truncate=True)
        self.assertEqual(len(result.points), 2)

    def test_rejects_undersized_sets(self) -> None:
        set_a = write_set(self.tmp, "one", [[1.0, 2.0]])
        set_b = write_set(self.tmp, "two", [[1.0, 2.0]] * 3)
        with self.assertRaises(TvlaError):
            assess(sorted(set_a.glob("*.json")), sorted(set_b.glob("*.json")))

    def test_group_names_appear_in_the_verdict(self) -> None:
        set_a = write_set(self.tmp, "ra", [[1.0, 2.0]] * 3)
        set_b = write_set(self.tmp, "rb", [[1.0, 2.0]] * 3)
        result = assess(
            sorted(set_a.glob("*.json")),
            sorted(set_b.glob("*.json")),
            fixed_name="random-A",
            random_name="random-B",
        )
        self.assertIn("random-A", result.verdict())
        self.assertIn("random-B", result.verdict())


class LoadingTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_reads_the_activity_proxy_series(self) -> None:
        path = write_trace(self.tmp / "trace.json", [1.0, 2.0, 3.0])
        self.assertEqual(load_series(path), [1.0, 2.0, 3.0])

    def test_reports_a_missing_series(self) -> None:
        path = self.tmp / "empty.json"
        path.write_text(json.dumps({"metadata": {}}), encoding="utf-8")
        with self.assertRaises(TvlaError):
            load_series(path)

    def test_expands_directories_and_files(self) -> None:
        directory = write_set(self.tmp, "set", [[1.0, 2.0]] * 3)
        self.assertEqual(len(expand_inputs([str(directory)])), 3)
        single = str(directory / "0000.json")
        self.assertEqual(expand_inputs([single]), [Path(single)])
        with self.assertRaises(TvlaError):
            expand_inputs([str(self.tmp / "missing-*.json")])


class ReportTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        rng = random.Random(17)
        self.fixed = write_set(self.tmp, "fixed", [[40.0, 20.0] for _ in range(30)])
        self.random = write_set(
            self.tmp,
            "random",
            [[rng.gauss(50.0, 3.0), rng.gauss(20.0, 3.0)] for _ in range(30)],
        )

    def test_payload_records_measurand_and_caveats(self) -> None:
        fixed_paths = sorted(self.fixed.glob("*.json"))
        random_paths = sorted(self.random.glob("*.json"))
        result = assess(fixed_paths, random_paths)
        payload = report_payload(result, fixed_paths=fixed_paths, random_paths=random_paths)
        self.assertIn("Goodwill", payload["methodology"])
        self.assertIn("PROXY", payload["measurand"])
        self.assertEqual(payload["threshold"], DEFAULT_THRESHOLD)
        self.assertEqual(payload["traces"]["fixed"], 30)
        self.assertEqual(len(payload["per_sample"]), 2)
        self.assertTrue(payload["leaking"])
        self.assertTrue(any("eprint.iacr.org/2019/1013" in note for note in payload["caveats"]))
        json.dumps(payload)  # the report must be plain JSON-serialisable

    def test_summary_mentions_the_verdict(self) -> None:
        result = assess(sorted(self.fixed.glob("*.json")), sorted(self.random.glob("*.json")))
        text = summarise(result)
        self.assertIn("VERDICT:", text)
        self.assertIn("max |t|", text)

    def test_cli_writes_a_report_and_honours_fail_flag(self) -> None:
        out = self.tmp / "report" / "tvla.json"
        with contextlib.redirect_stdout(io.StringIO()):
            status = main(
                [
                    "--fixed",
                    str(self.fixed),
                    "--random",
                    str(self.random),
                    "--out",
                    str(out),
                    "--summary",
                ]
            )
        self.assertEqual(status, 0)  # leakage does not fail the run by default
        payload = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(payload["verdict"].startswith("LEAKAGE DETECTED"))

        with contextlib.redirect_stdout(io.StringIO()):
            status = main(
                [
                    "--fixed",
                    str(self.fixed),
                    "--random",
                    str(self.random),
                    "--out",
                    str(out),
                    "--fail-on-leakage",
                ]
            )
        self.assertEqual(status, 1)

    def test_cli_reports_input_errors(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()) as captured:
            status = main(["--fixed", str(self.tmp / "nope-*.json"), "--random", str(self.random)])
        self.assertEqual(status, 2)
        self.assertIn("no traces matched", captured.getvalue())


if __name__ == "__main__":
    unittest.main()
