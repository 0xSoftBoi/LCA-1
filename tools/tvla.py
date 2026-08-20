#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixed-vs-random leakage assessment (TVLA) over LCA-1 activity traces.

Implements the non-specific fixed-vs-random Test Vector Leakage Assessment of
Goodwill, Jun, Jaffe and Rohatgi, "A testing methodology for side channel
resistance validation" (NIST NIAT Workshop, 2011): Welch's two-sample t-test is
computed independently at every sample point of two trace sets, and any point
with |t| > 4.5 is reported as a detected difference.

Inputs are traces emitted by ``tools/power_trace_from_vcd.py``. The series
under test is ``metadata.activity_proxy.per_cycle`` - a **weighted toggle
count**, i.e. a simulation proxy for switching activity, NOT a power
measurement and NOT a physical trace. Read ``docs/LEAKAGE_METHODOLOGY.md``
before quoting any number this tool prints.

Two honest caveats are built into the reporting:

* A passing (below-threshold) result is not a security claim. It bounds only
  what this proxy, this stimulus and this trace count can see. See the
  Whitnall-Oswald critique of TVLA's inferential power
  (https://eprint.iacr.org/2019/1013).
* In a noiseless RTL simulation a fixed input set produces bit-identical
  traces, so its per-point variance is exactly zero. Welch's denominator is
  then driven by the random set alone (or is zero), which inflates |t| far
  beyond anything a bench measurement would produce. Degenerate points - zero
  variance in both sets with unequal means - are reported separately rather
  than laundered into a finite t-value.

Usage
-----
    python3 tools/tvla.py --fixed traces/fixed --random traces/random \\
        --out report.json --summary
"""

from __future__ import annotations

import argparse
import glob as globlib
import json
import math
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

TOOL_NAME = "tools/tvla.py"
TOOL_VERSION = "1.0.0"
DEFAULT_THRESHOLD = 4.5
SERIES_POINTER = "metadata.activity_proxy.per_cycle"


class TvlaError(ValueError):
    """Raised when trace sets cannot be compared."""


# --------------------------------------------------------------------------
# Incremental statistics
# --------------------------------------------------------------------------


@dataclass
class Welford:
    """Numerically stable streaming mean/variance (Welford, 1962)."""

    count: int = 0
    mean: float = 0.0
    m2: float = 0.0

    def update(self, value: float) -> None:
        self.count += 1
        delta = value - self.mean
        self.mean += delta / self.count
        self.m2 += delta * (value - self.mean)

    @property
    def variance(self) -> float:
        """Unbiased sample variance; 0.0 for fewer than two observations."""
        if self.count < 2:
            return 0.0
        return self.m2 / (self.count - 1)


@dataclass
class PointResult:
    index: int
    t: float | None
    mean_fixed: float
    mean_random: float
    var_fixed: float
    var_random: float
    degenerate: bool = False

    @property
    def abs_t(self) -> float:
        if self.t is None:
            return math.inf if self.degenerate else 0.0
        return abs(self.t)


@dataclass
class TvlaResult:
    threshold: float
    n_fixed: int
    n_random: int
    points: list[PointResult] = field(default_factory=list)
    fixed_name: str = "fixed"
    random_name: str = "random"

    @property
    def finite_abs_t(self) -> list[float]:
        return [point.abs_t for point in self.points if point.t is not None]

    @property
    def degenerate_points(self) -> list[PointResult]:
        return [point for point in self.points if point.degenerate]

    @property
    def exceeding(self) -> list[PointResult]:
        return [point for point in self.points if point.abs_t > self.threshold]

    @property
    def max_abs_t(self) -> float:
        if not self.points:
            return 0.0
        return max(point.abs_t for point in self.points)

    @property
    def max_point(self) -> PointResult:
        return max(self.points, key=lambda point: point.abs_t)

    @property
    def leaking(self) -> bool:
        return bool(self.exceeding)

    def verdict(self) -> str:
        total = len(self.points)
        count = len(self.exceeding)
        if self.leaking:
            if self.degenerate_points:
                magnitude = (
                    f"max |t| = infinite at {len(self.degenerate_points)} deterministic point(s)"
                )
                finite = self.finite_abs_t
                if finite:
                    magnitude += f"; max finite |t| = {max(finite):.2f}"
            else:
                magnitude = f"max |t| = {self.max_abs_t:.2f}"
            return (
                f"LEAKAGE DETECTED: {count}/{total} sample points exceed "
                f"|t| > {self.threshold} ({magnitude}) over "
                f"{self.n_fixed} {self.fixed_name} and {self.n_random} "
                f"{self.random_name} traces. "
                "The activity proxy is input-dependent; this design makes no "
                "side-channel-resistance claim."
            )
        return (
            f"NO LEAKAGE DETECTED at |t| > {self.threshold}: 0/{total} sample points "
            f"exceed the threshold over {self.n_fixed} {self.fixed_name} and "
            f"{self.n_random} {self.random_name} traces. This is a bound on what "
            "this proxy and this trace count can see, not evidence of "
            "side-channel resistance."
        )


def welch_t(fixed: Welford, random_set: Welford) -> tuple[float | None, bool]:
    """Welch's t statistic for one sample point.

    Returns ``(t, degenerate)``. ``t`` is ``None`` when both sets have zero
    variance and different means: the difference is deterministic and the
    statistic diverges, which is flagged rather than clipped.
    """
    if fixed.count < 2 or random_set.count < 2:
        raise TvlaError("each trace set needs at least two traces")
    denominator = math.sqrt(fixed.variance / fixed.count + random_set.variance / random_set.count)
    difference = fixed.mean - random_set.mean
    if denominator == 0.0:
        if difference == 0.0:
            return 0.0, False
        return None, True
    return difference / denominator, False


# --------------------------------------------------------------------------
# Trace loading
# --------------------------------------------------------------------------


def _dig(payload: Any, pointer: str) -> Any:
    node = payload
    for key in pointer.split("."):
        if not isinstance(node, dict) or key not in node:
            raise TvlaError(f"trace has no {pointer!r}")
        node = node[key]
    return node


def load_series(path: Path, pointer: str = SERIES_POINTER) -> list[float]:
    """Extract the per-sample activity series from one trace file."""
    payload = json.loads(path.read_text(encoding="utf-8"))
    series = _dig(payload, pointer)
    if not isinstance(series, list) or not series:
        raise TvlaError(f"{path}: {pointer} is not a non-empty array")
    try:
        return [float(value) for value in series]
    except (TypeError, ValueError) as exc:
        raise TvlaError(f"{path}: {pointer} contains non-numeric values") from exc


def expand_inputs(entries: Iterable[str]) -> list[Path]:
    """Expand files, directories and globs into a sorted list of trace files."""
    paths: list[Path] = []
    for entry in entries:
        candidate = Path(entry)
        if candidate.is_dir():
            paths.extend(sorted(candidate.glob("*.json")))
        elif candidate.exists():
            paths.append(candidate)
        else:
            matches = sorted(Path(match) for match in globlib.glob(entry))
            if not matches:
                raise TvlaError(f"no traces matched {entry!r}")
            paths.extend(matches)
    if not paths:
        raise TvlaError("no trace files given")
    return paths


def assess(
    fixed_paths: Sequence[Path],
    random_paths: Sequence[Path],
    *,
    threshold: float = DEFAULT_THRESHOLD,
    pointer: str = SERIES_POINTER,
    truncate: bool = False,
    fixed_name: str = "fixed",
    random_name: str = "random",
) -> TvlaResult:
    """Run the per-sample Welch t-test over two trace sets."""
    if len(fixed_paths) < 2 or len(random_paths) < 2:
        raise TvlaError("each trace set needs at least two traces")

    lengths: set[int] = set()
    fixed_series = [load_series(path, pointer) for path in fixed_paths]
    random_series = [load_series(path, pointer) for path in random_paths]
    for series in (*fixed_series, *random_series):
        lengths.add(len(series))
    if len(lengths) != 1:
        if not truncate:
            raise TvlaError(
                f"traces have differing lengths {sorted(lengths)}; pass --truncate to "
                "compare the common prefix"
            )
        length = min(lengths)
    else:
        length = lengths.pop()

    fixed_stats = [Welford() for _ in range(length)]
    random_stats = [Welford() for _ in range(length)]
    for series in fixed_series:
        for index in range(length):
            fixed_stats[index].update(series[index])
    for series in random_series:
        for index in range(length):
            random_stats[index].update(series[index])

    result = TvlaResult(
        threshold=threshold,
        n_fixed=len(fixed_series),
        n_random=len(random_series),
        fixed_name=fixed_name,
        random_name=random_name,
    )
    for index, (left, right) in enumerate(zip(fixed_stats, random_stats)):
        value, degenerate = welch_t(left, right)
        result.points.append(
            PointResult(
                index=index,
                t=value,
                mean_fixed=left.mean,
                mean_random=right.mean,
                var_fixed=left.variance,
                var_random=right.variance,
                degenerate=degenerate,
            )
        )
    return result


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------


def report_payload(
    result: TvlaResult,
    *,
    fixed_paths: Sequence[Path],
    random_paths: Sequence[Path],
    pointer: str = SERIES_POINTER,
    label: str = "fixed-vs-random",
) -> dict[str, Any]:
    finite = result.finite_abs_t
    return {
        "tool": f"{TOOL_NAME} {TOOL_VERSION}",
        "methodology": (
            "Goodwill, Jun, Jaffe, Rohatgi (2011) non-specific fixed-vs-random TVLA; "
            "Welch two-sample t-test per sample point"
        ),
        "comparison": label,
        "measurand": (
            "weighted toggle count per clock cycle from RTL simulation "
            "(PROXY for switching activity; not watts, not a physical measurement)"
        ),
        "series_pointer": pointer,
        "threshold": result.threshold,
        "traces": {
            "group_a_name": result.fixed_name,
            "group_b_name": result.random_name,
            "fixed": result.n_fixed,
            "random": result.n_random,
            "fixed_files": [str(path) for path in fixed_paths],
            "random_files": [str(path) for path in random_paths],
        },
        "sample_points": len(result.points),
        "points_exceeding_threshold": len(result.exceeding),
        "max_abs_t": None if result.degenerate_points else result.max_abs_t,
        "max_abs_t_finite": max(finite) if finite else None,
        "max_abs_t_index": result.max_point.index if result.points else None,
        "degenerate_points": [
            {
                "index": point.index,
                "mean_fixed": point.mean_fixed,
                "mean_random": point.mean_random,
                "note": "zero variance in both sets with unequal means; |t| diverges",
            }
            for point in result.degenerate_points
        ],
        "leaking": result.leaking,
        "verdict": result.verdict(),
        "per_sample": [
            {
                "index": point.index,
                "t": point.t,
                "degenerate": point.degenerate,
                "mean_fixed": point.mean_fixed,
                "mean_random": point.mean_random,
                "var_fixed": point.var_fixed,
                "var_random": point.var_random,
                "exceeds_threshold": point.abs_t > result.threshold,
            }
            for point in result.points
        ],
        "caveats": [
            "The measurand is a simulation toggle-count proxy, not measured power.",
            "A noiseless simulator gives the fixed set zero variance, inflating |t|.",
            "A below-threshold result is not evidence of side-channel resistance "
            "(Whitnall and Oswald, https://eprint.iacr.org/2019/1013).",
        ],
    }


def summarise(result: TvlaResult, *, top: int = 10) -> str:
    lines = [
        f"sample points          : {len(result.points)}",
        f"traces                 : {result.n_fixed} {result.fixed_name} / "
        f"{result.n_random} {result.random_name}",
        f"threshold              : |t| > {result.threshold}",
        f"points over threshold  : {len(result.exceeding)}",
    ]
    finite = result.finite_abs_t
    if result.degenerate_points:
        lines.append(
            f"max |t|                : infinite (deterministic difference at "
            f"{len(result.degenerate_points)} point(s))"
        )
        if finite:
            lines.append(f"max finite |t|         : {max(finite):.3f}")
    else:
        point = result.max_point
        lines.append(f"max |t|                : {result.max_abs_t:.3f} at sample {point.index}")
    ranked = sorted(result.points, key=lambda item: item.abs_t, reverse=True)[:top]
    lines.append("top sample points      :")
    for point in ranked:
        shown = "inf" if point.t is None else f"{point.t:+.3f}"
        lines.append(
            f"  sample {point.index:>4}  t={shown:>10}  "
            f"mean[{result.fixed_name}]={point.mean_fixed:.3f}  "
            f"mean[{result.random_name}]={point.mean_random:.3f}"
        )
    lines.append("")
    lines.append(f"VERDICT: {result.verdict()}")
    return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Fixed-vs-random TVLA (Welch t-test, |t| > 4.5) over activity traces "
            "emitted by tools/power_trace_from_vcd.py."
        )
    )
    parser.add_argument(
        "--fixed",
        nargs="+",
        required=True,
        help="fixed-input trace files, directories, or globs",
    )
    parser.add_argument(
        "--random",
        nargs="+",
        required=True,
        help="random-input trace files, directories, or globs",
    )
    parser.add_argument("--out", type=Path, help="write the full JSON report here")
    parser.add_argument("--summary", action="store_true", help="print a human-readable summary")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--series", default=SERIES_POINTER, help="dotted pointer to the series")
    parser.add_argument(
        "--truncate",
        action="store_true",
        help="compare the common prefix when trace lengths differ",
    )
    parser.add_argument(
        "--label", default="fixed-vs-random", help="comparison label recorded in the report"
    )
    parser.add_argument("--fixed-name", default="fixed", help="name of the first trace set")
    parser.add_argument("--random-name", default="random", help="name of the second trace set")
    parser.add_argument(
        "--fail-on-leakage",
        action="store_true",
        help="exit non-zero when the threshold is exceeded (off by default: this "
        "repository publishes the negative result rather than gating on it)",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        fixed_paths = expand_inputs(args.fixed)
        random_paths = expand_inputs(args.random)
        result = assess(
            fixed_paths,
            random_paths,
            threshold=args.threshold,
            pointer=args.series,
            truncate=args.truncate,
            fixed_name=args.fixed_name,
            random_name=args.random_name,
        )
    except TvlaError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    payload = report_payload(
        result,
        fixed_paths=fixed_paths,
        random_paths=random_paths,
        pointer=args.series,
        label=args.label,
    )
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.summary or not args.out:
        print(summarise(result))
    if args.fail_on_leakage and result.leaking:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
