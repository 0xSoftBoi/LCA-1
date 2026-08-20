#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Per-cycle switching-activity trace generator for LCA-1 VCD dumps.

WHAT THIS IS
------------
This tool parses a VCD written by an RTL simulator (Icarus Verilog / ``vvp``
in this repository) and emits a trace in the versioned
``spec/power-trace.schema.json`` format with ``source = "simulator"``.

The per-cycle quantity it computes is a **weighted toggle count**: for every
tracked signal, the Hamming distance between its value at consecutive rising
clock edges, multiplied by an optional per-signal weight, summed over all
tracked signals.

WHAT THIS IS NOT
----------------
A toggle count is a *proxy* for dynamic switching activity, not a power
measurement. It carries no unit of energy. There is:

* no per-net capacitance and no cell-level load model;
* no glitch/hazard modelling (values are read once per clock edge, so
  intra-cycle transitions are invisible);
* no leakage/static power, no short-circuit power, no clock-tree or
  interconnect contribution;
* no supply voltage, no process corner, no temperature;
* no relationship to measured silicon.

Accordingly the emitted samples carry ``estimated_watts = null`` and
``measured_watts = null``. The activity proxy is carried in
``metadata.activity_proxy`` (schema v1.0 forbids extra sample fields), clearly
labelled as a proxy. Converting these numbers to watts requires the
gate-level flow described in ``docs/LEAKAGE_METHODOLOGY.md``.

Usage
-----
    python3 tools/power_trace_from_vcd.py --vcd run.vcd --out trace.json --summary
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from fractions import Fraction
from pathlib import Path
from typing import Any, Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:  # allow direct script execution
    sys.path.insert(0, str(REPO_ROOT))

from model.power_contract import ActivitySample, PowerTrace  # noqa: E402

GENERATOR_NAME = "tools/power_trace_from_vcd.py"
GENERATOR_VERSION = "1.0.0"
SCHEMA_PATH = REPO_ROOT / "spec" / "power-trace.schema.json"

#: Variable kinds that carry no switching activity or no bit vector.
NON_TOGGLING_VAR_TYPES = frozenset({"parameter", "real", "realtime", "event", "string"})

TIMESCALE_UNITS = {
    "s": Fraction(1),
    "ms": Fraction(1, 10**3),
    "us": Fraction(1, 10**6),
    "ns": Fraction(1, 10**9),
    "ps": Fraction(1, 10**12),
    "fs": Fraction(1, 10**15),
}

_NANOSECOND = Fraction(1, 10**9)


class VcdError(ValueError):
    """Raised when a VCD cannot be parsed or lacks what the tool needs."""


class SchemaError(ValueError):
    """Raised when an emitted payload does not conform to the trace schema."""


# --------------------------------------------------------------------------
# VCD parsing
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class VcdVar:
    """One ``$var`` declaration."""

    ident: str
    path: str
    name: str
    width: int
    var_type: str

    @property
    def togglable(self) -> bool:
        return self.var_type not in NON_TOGGLING_VAR_TYPES


@dataclass
class TimeBlock:
    """All value changes stamped at one simulation time."""

    time: int
    changes: dict[str, str] = field(default_factory=dict)


@dataclass
class VcdFile:
    date: str
    version: str
    timescale_text: str
    timescale_seconds: Fraction
    variables: list[VcdVar]
    time_blocks: list[TimeBlock]

    def widths(self) -> dict[str, int]:
        """Bit width per identifier code (aliases share an identifier)."""
        widths: dict[str, int] = {}
        for var in self.variables:
            widths.setdefault(var.ident, var.width)
        return widths


_BIT_RANGE_RE = re.compile(r"\s*\[[^\]]*\]\s*$")


def _strip_bit_range(name: str) -> str:
    return _BIT_RANGE_RE.sub("", name).strip()


def _parse_timescale(text: str) -> Fraction:
    compact = text.replace(" ", "").strip()
    match = re.fullmatch(r"(\d+)(s|ms|us|ns|ps|fs)", compact)
    if not match:
        raise VcdError(f"unsupported $timescale value: {text!r}")
    magnitude = int(match.group(1))
    if magnitude not in (1, 10, 100):
        raise VcdError(f"unsupported $timescale magnitude: {text!r}")
    return magnitude * TIMESCALE_UNITS[match.group(2)]


def _normalise_vector(value: str, width: int) -> str:
    """Left-extend a VCD vector literal to ``width`` per IEEE 1364 rules."""
    value = value.lower()
    if not value:
        return "x" * width
    if len(value) < width:
        fill = value[0] if value[0] in "xz" else "0"
        value = fill * (width - len(value)) + value
    elif len(value) > width:
        value = value[-width:]
    return value


def parse_vcd(path: Path | str) -> VcdFile:
    """Parse a VCD file into declarations plus time-ordered change blocks."""
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    marker = text.find("$enddefinitions")
    if marker < 0:
        raise VcdError("VCD has no $enddefinitions section")
    body_start = text.find("$end", marker + len("$enddefinitions"))
    if body_start < 0:
        raise VcdError("unterminated $enddefinitions section")
    header_text = text[:marker]
    body_text = text[body_start + len("$end"):]

    date = ""
    version = ""
    timescale_text = ""
    variables: list[VcdVar] = []
    scope: list[str] = []

    tokens = header_text.split()
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "$var":
            end = tokens.index("$end", index)
            fields = tokens[index + 1:end]
            if len(fields) < 4:
                raise VcdError(f"malformed $var declaration: {' '.join(fields)}")
            var_type, width_text, ident = fields[0], fields[1], fields[2]
            name = _strip_bit_range(" ".join(fields[3:]))
            try:
                width = int(width_text)
            except ValueError as exc:  # pragma: no cover - malformed input
                raise VcdError(f"non-integer $var width: {width_text!r}") from exc
            full_path = ".".join(scope + [name]) if scope else name
            variables.append(
                VcdVar(ident=ident, path=full_path, name=name, width=width, var_type=var_type)
            )
            index = end + 1
        elif token == "$scope":
            end = tokens.index("$end", index)
            fields = tokens[index + 1:end]
            if len(fields) >= 2:
                scope.append(fields[1])
            index = end + 1
        elif token == "$upscope":
            end = tokens.index("$end", index)
            if scope:
                scope.pop()
            index = end + 1
        elif token in ("$date", "$version", "$timescale", "$comment"):
            end = tokens.index("$end", index)
            payload = " ".join(tokens[index + 1:end])
            if token == "$date":
                date = payload
            elif token == "$version":
                version = payload
            elif token == "$timescale":
                timescale_text = payload
            index = end + 1
        else:
            index += 1

    if not variables:
        raise VcdError("VCD declares no signals")
    if not timescale_text:
        raise VcdError("VCD has no $timescale")

    widths: dict[str, int] = {}
    for var in variables:
        widths.setdefault(var.ident, var.width)

    blocks: list[TimeBlock] = [TimeBlock(time=0)]
    in_comment = False
    for raw_line in body_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if in_comment:
            if line.endswith("$end") or line == "$end":
                in_comment = False
            continue
        if line.startswith("$"):
            keyword = line.split()[0]
            if keyword == "$comment":
                if not line.endswith("$end"):
                    in_comment = True
                continue
            # $dumpvars/$dumpall/$dumpon/$dumpoff/$end carry no data themselves;
            # their value lines are ordinary change records.
            continue
        if line.startswith("#"):
            try:
                stamp = int(line[1:])
            except ValueError as exc:
                raise VcdError(f"malformed time stamp: {line!r}") from exc
            if stamp < blocks[-1].time:
                raise VcdError("VCD time stamps are not monotonic")
            if stamp != blocks[-1].time:
                blocks.append(TimeBlock(time=stamp))
            continue
        head = line[0]
        if head in "bB":
            parts = line.split()
            if len(parts) < 2:
                raise VcdError(f"malformed vector change: {line!r}")
            ident = parts[-1]
            width = widths.get(ident)
            if width is None:
                continue
            blocks[-1].changes[ident] = _normalise_vector(parts[0][1:], width)
        elif head in "rR":
            parts = line.split()
            if len(parts) < 2:
                raise VcdError(f"malformed real change: {line!r}")
            blocks[-1].changes[parts[-1]] = parts[0].lower()
        elif head in "sS":
            parts = line.split()
            if len(parts) < 2:
                raise VcdError(f"malformed string change: {line!r}")
            blocks[-1].changes[parts[-1]] = parts[0]
        elif head in "01xXzZuUwWlLhH-":
            ident = line[1:].strip()
            if not ident:
                raise VcdError(f"scalar change without identifier: {line!r}")
            width = widths.get(ident, 1)
            blocks[-1].changes[ident] = _normalise_vector(head, width)
        else:
            raise VcdError(f"unrecognised VCD record: {line!r}")

    return VcdFile(
        date=date,
        version=version,
        timescale_text=timescale_text,
        timescale_seconds=_parse_timescale(timescale_text),
        variables=variables,
        time_blocks=blocks,
    )


# --------------------------------------------------------------------------
# Activity computation
# --------------------------------------------------------------------------


def hamming_distance(previous: str, current: str) -> int:
    """Count differing bit positions between two 4-state VCD bit strings.

    ``x``/``z`` are ordinary symbols: a position counts as a transition when
    the two symbols differ (``0``->``x`` counts, ``x``->``x`` does not). Values
    of unequal length are compared right-aligned after zero/x extension.
    """
    if len(previous) != len(current):
        width = max(len(previous), len(current))
        previous = _normalise_vector(previous, width)
        current = _normalise_vector(current, width)
    return sum(1 for left, right in zip(previous, current) if left != right)


@dataclass
class TrackedSignal:
    ident: str
    path: str
    width: int
    weight: float


@dataclass
class CycleActivity:
    timestamp_ns: int
    toggles: float
    state: str
    active_lanes: int


@dataclass
class StateRules:
    """How VCD signal values map onto the contract's activity states."""

    reset_ident: str | None = None
    reset_active_low: bool = True
    busy_ident: str | None = None
    modulus_ident: str | None = None
    fault_ident: str | None = None
    kem_modulus: int = 3329
    dsa_modulus: int = 8380417
    default_active_state: str = "kem"

    def classify(self, values: dict[str, str]) -> str:
        if self.reset_ident is not None:
            reset = values.get(self.reset_ident, "x")
            asserted = reset == "0" if self.reset_active_low else reset == "1"
            if asserted:
                # Reset is this slice's only register-clearing path, so the
                # contract's `zeroize` state is the honest label for it.
                return "zeroize"
        if self.fault_ident is not None and values.get(self.fault_ident) == "1":
            return "fault"
        if self.busy_ident is not None and values.get(self.busy_ident) == "1":
            if self.modulus_ident is not None:
                raw = values.get(self.modulus_ident, "")
                if raw and all(char in "01" for char in raw):
                    modulus = int(raw, 2)
                    if modulus == self.kem_modulus:
                        return "kem"
                    if modulus == self.dsa_modulus:
                        return "dsa"
            return self.default_active_state
        return "idle"


def select_signals(
    vcd: VcdFile,
    *,
    scopes: Sequence[str] = (),
    excludes: Sequence[str] = (),
    weights: Sequence[tuple[str, float]] = (),
    exclude_idents: Iterable[str] = (),
    count_aliases: bool = False,
) -> tuple[list[TrackedSignal], list[str]]:
    """Choose which declared signals contribute to the activity proxy.

    Returns ``(tracked, skipped_paths)``. Identifier codes are de-duplicated by
    default: iverilog declares the same physical net once per scope it appears
    in, and counting every declaration would multiply-count one net.
    """
    banned = set(exclude_idents)
    tracked: list[TrackedSignal] = []
    skipped: list[str] = []
    seen: set[str] = set()
    for var in sorted(vcd.variables, key=lambda item: (item.path, item.ident)):
        if scopes and not any(
            var.path == scope or var.path.startswith(scope + ".") for scope in scopes
        ):
            continue
        if var.ident in banned:
            skipped.append(var.path)
            continue
        if not var.togglable:
            skipped.append(var.path)
            continue
        if any(fnmatch.fnmatch(var.path, pattern) for pattern in excludes):
            skipped.append(var.path)
            continue
        if not count_aliases and var.ident in seen:
            continue
        seen.add(var.ident)
        weight = 1.0
        for pattern, factor in weights:
            if fnmatch.fnmatch(var.path, pattern):
                weight = factor
        tracked.append(
            TrackedSignal(ident=var.ident, path=var.path, width=var.width, weight=weight)
        )
    return tracked, skipped


def resolve_signal(vcd: VcdFile, spec: str | None) -> str | None:
    """Resolve a full path or bare signal name to a single identifier code."""
    if not spec:
        return None
    exact = {var.ident for var in vcd.variables if var.path == spec}
    if len(exact) == 1:
        return exact.pop()
    if len(exact) > 1:
        raise VcdError(f"signal path {spec!r} maps to multiple identifiers")
    by_name = {var.ident for var in vcd.variables if var.name == spec}
    if not by_name:
        raise VcdError(f"signal {spec!r} not found in VCD")
    if len(by_name) > 1:
        paths = sorted(var.path for var in vcd.variables if var.name == spec)
        raise VcdError(
            f"signal name {spec!r} is ambiguous ({', '.join(paths)}); give the full path"
        )
    return by_name.pop()


def _time_to_ns(time: int, scale: Fraction) -> int:
    value = Fraction(time) * scale / _NANOSECOND
    if value.denominator != 1:
        raise VcdError(
            "clock edge at a sub-nanosecond time cannot be represented as an "
            "integer nanosecond timestamp required by the trace schema"
        )
    return int(value)


def compute_cycle_activity(
    vcd: VcdFile,
    tracked: Sequence[TrackedSignal],
    clock_ident: str,
    rules: StateRules,
) -> list[CycleActivity]:
    """Sample the design once per rising clock edge.

    The activity reported at edge *N* is the weighted toggle count accumulated
    between edge *N-1* and edge *N*; the state reported at edge *N* is the
    state the design held **during** that interval (the values latched at edge
    *N-1*). The first sample compares against the values in force immediately
    before the first rising edge, so uninitialised (``x``) registers count as
    toggling once when reset first drives them.
    """
    if not tracked:
        raise VcdError("no signals selected for the activity proxy")

    values: dict[str, str] = {}
    pre_block: dict[str, str] = {}
    previous_clock = "x"
    previous_snapshot: dict[str, str] | None = None
    samples: list[CycleActivity] = []

    state_idents = [
        ident
        for ident in (rules.reset_ident, rules.busy_ident, rules.modulus_ident, rules.fault_ident)
        if ident is not None
    ]

    for block in vcd.time_blocks:
        # Values in force *during* the cycle that ends at this block, i.e.
        # before this block's (post-edge) updates are applied.
        state_values = {ident: values.get(ident, "x") for ident in state_idents}
        if previous_snapshot is None:
            pre_block = {
                signal.ident: values.get(signal.ident, "x" * signal.width) for signal in tracked
            }
        values.update(block.changes)
        clock = values.get(clock_ident, "x")
        rising = clock == "1" and previous_clock != "1"
        previous_clock = clock
        if not rising:
            continue

        snapshot = {signal.ident: values.get(signal.ident, "x" * signal.width) for signal in tracked}
        reference = pre_block if previous_snapshot is None else previous_snapshot

        toggles = 0.0
        for signal in tracked:
            distance = hamming_distance(reference[signal.ident], snapshot[signal.ident])
            if distance:
                toggles += signal.weight * distance

        state = rules.classify(state_values)
        samples.append(
            CycleActivity(
                timestamp_ns=_time_to_ns(block.time, vcd.timescale_seconds),
                toggles=toggles,
                state=state,
                active_lanes=1 if state in ("kem", "dsa") else 0,
            )
        )
        previous_snapshot = snapshot

    if len(samples) < 2:
        raise VcdError(
            f"VCD contains {len(samples)} rising clock edge(s); the trace schema "
            "requires at least two samples"
        )
    return samples


# --------------------------------------------------------------------------
# Trace assembly
# --------------------------------------------------------------------------


def _run(command: Sequence[str]) -> str | None:
    if shutil.which(command[0]) is None:
        return None
    try:
        result = subprocess.run(  # noqa: S603 - fixed, read-only commands
            list(command),
            capture_output=True,
            text=True,
            timeout=30,
            cwd=str(REPO_ROOT),
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    output = (result.stdout or "") + (result.stderr or "")
    for line in output.splitlines():
        line = line.strip()
        if line:
            return line
    return None


def collect_provenance(probe_tools: bool = True) -> dict[str, Any]:
    """Read-only provenance: source commit and local tool versions."""
    provenance: dict[str, Any] = {
        "source_commit": None,
        "source_tree_dirty": None,
        "tool_versions": {
            "generator": f"{GENERATOR_NAME} {GENERATOR_VERSION}",
            "python": sys.version.split()[0],
            "iverilog_in_path": None,
            "vvp_in_path": None,
        },
    }
    if not probe_tools:
        return provenance
    commit = _run(["git", "rev-parse", "HEAD"])
    if commit and re.fullmatch(r"[0-9a-f]{40}", commit):
        provenance["source_commit"] = commit
        status = _run(["git", "status", "--porcelain"])
        provenance["source_tree_dirty"] = status is not None and status != ""
    provenance["tool_versions"]["iverilog_in_path"] = _run(["iverilog", "-V"])
    provenance["tool_versions"]["vvp_in_path"] = _run(["vvp", "-V"])
    return provenance


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_trace(
    *,
    vcd: VcdFile,
    vcd_path: Path,
    samples: Sequence[CycleActivity],
    tracked: Sequence[TrackedSignal],
    skipped: Sequence[str],
    clock_path: str,
    hardware_id: str,
    operation: str,
    workload: str,
    extra_metadata: dict[str, str] | None = None,
    probe_tools: bool = True,
) -> PowerTrace:
    intervals = [
        later.timestamp_ns - earlier.timestamp_ns for earlier, later in zip(samples, samples[1:])
    ]
    uniform = len(set(intervals)) == 1
    interval_ns = intervals[0] if uniform else round(sum(intervals) / len(intervals))
    if interval_ns <= 0:
        raise VcdError("clock edges are not separated by at least one nanosecond")
    clock_hz = round(1_000_000_000 / interval_ns)

    toggles = [sample.toggles for sample in samples]
    provenance = collect_provenance(probe_tools=probe_tools)

    metadata: dict[str, Any] = {
        "activity_proxy": {
            "unit": "weighted_toggle_count_per_clock_cycle",
            "definition": (
                "sum over tracked VCD signals of (weight x Hamming distance between "
                "the signal value at consecutive rising clock edges)"
            ),
            "is_power_measurement": False,
            "is_power_estimate": False,
            "warning": (
                "PROXY ONLY. This is a switching-activity count, not watts. No "
                "capacitance, no glitch modelling, no voltage, no corner, no "
                "silicon measurement. Do not convert to power without the "
                "gate-level flow in docs/LEAKAGE_METHODOLOGY.md."
            ),
            "per_cycle": toggles,
            "max": max(toggles),
            "mean": sum(toggles) / len(toggles),
            "total": sum(toggles),
            "tracked_signal_count": len(tracked),
            "tracked_signals": [signal.path for signal in tracked],
            "signal_weights": {
                signal.path: signal.weight for signal in tracked if signal.weight != 1.0
            },
            "excluded_signals": list(skipped),
            "clock_signal": clock_path,
            "alias_handling": "one count per unique VCD identifier code",
        },
        "trace_source_detail": (
            "RTL (pre-synthesis) event simulation VCD; zero-delay, no cell library"
        ),
        "simulation_only": True,
        "workload": workload,
        "operation_parameters": dict(extra_metadata or {}),
        "clock_hz": clock_hz,
        "clock_period_ns": interval_ns,
        "sample_interval_ns": interval_ns,
        "sample_interval_uniform": uniform,
        "sample_alignment": (
            "one sample per rising clock edge; the sample reports activity for the "
            "cycle ending at that edge and the state held during that cycle"
        ),
        "voltage_v": None,
        "voltage_note": "no operating point; RTL simulation has no supply",
        "ambient_c": None,
        "cooling": None,
        "instrument_bandwidth_hz": None,
        "instrument": None,
        "watts_basis": "neither estimated nor measured",
        "idle_power_treatment": "not modelled; static/leakage power is absent from this proxy",
        "repetitions": 1,
        "vcd": {
            "path": str(vcd_path),
            "sha256": _sha256(vcd_path),
            "date": vcd.date,
            "version": vcd.version,
            "timescale": vcd.timescale_text,
            "declared_vars": len(vcd.variables),
            "unique_identifiers": len({var.ident for var in vcd.variables}),
        },
        **provenance,
    }

    trace = PowerTrace(
        source="simulator",
        hardware_id=hardware_id,
        operation=operation,
        samples=[
            ActivitySample(
                timestamp_ns=sample.timestamp_ns,
                state=sample.state,
                active_lanes=sample.active_lanes,
                clock_hz=clock_hz,
                estimated_watts=None,
                measured_watts=None,
            )
            for sample in samples
        ],
        metadata=metadata,
    )
    trace.validate()
    return trace


def trace_payload(trace: PowerTrace) -> dict[str, Any]:
    """The exact JSON object ``PowerTrace.to_json`` writes."""
    return {
        "schema_version": "1.0",
        "source": trace.source,
        "hardware_id": trace.hardware_id,
        "operation": trace.operation,
        "metadata": trace.metadata,
        "samples": [
            {
                "timestamp_ns": sample.timestamp_ns,
                "state": sample.state,
                "active_lanes": sample.active_lanes,
                "clock_hz": sample.clock_hz,
                "estimated_watts": sample.estimated_watts,
                "measured_watts": sample.measured_watts,
            }
            for sample in trace.samples
        ],
    }


# --------------------------------------------------------------------------
# Minimal JSON Schema checker (stdlib only)
# --------------------------------------------------------------------------


def validate_against_schema(payload: Any, schema: dict[str, Any], path: str = "$") -> None:
    """Validate against the subset of JSON Schema used by the trace contract."""
    if "const" in schema and payload != schema["const"]:
        raise SchemaError(f"{path}: expected const {schema['const']!r}, got {payload!r}")
    if "enum" in schema and payload not in schema["enum"]:
        raise SchemaError(f"{path}: {payload!r} is not one of {schema['enum']}")

    types = schema.get("type")
    if types is not None:
        allowed = [types] if isinstance(types, str) else list(types)
        if not any(_is_type(payload, name) for name in allowed):
            raise SchemaError(f"{path}: expected type {allowed}, got {type(payload).__name__}")

    if isinstance(payload, bool):
        return
    if isinstance(payload, (int, float)):
        minimum = schema.get("minimum")
        if minimum is not None and payload < minimum:
            raise SchemaError(f"{path}: {payload} is below minimum {minimum}")
    if isinstance(payload, str):
        min_length = schema.get("minLength")
        if min_length is not None and len(payload) < min_length:
            raise SchemaError(f"{path}: string shorter than minLength {min_length}")
    if isinstance(payload, list):
        min_items = schema.get("minItems")
        if min_items is not None and len(payload) < min_items:
            raise SchemaError(f"{path}: array shorter than minItems {min_items}")
        item_schema = schema.get("items")
        if isinstance(item_schema, dict):
            for index, item in enumerate(payload):
                validate_against_schema(item, item_schema, f"{path}[{index}]")
    if isinstance(payload, dict):
        for name in schema.get("required", []):
            if name not in payload:
                raise SchemaError(f"{path}: missing required property {name!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in payload:
                if key not in properties:
                    raise SchemaError(f"{path}: additional property {key!r} is not allowed")
        for key, value in payload.items():
            if key in properties:
                validate_against_schema(value, properties[key], f"{path}.{key}")


def _is_type(payload: Any, name: str) -> bool:
    if name == "object":
        return isinstance(payload, dict)
    if name == "array":
        return isinstance(payload, list)
    if name == "string":
        return isinstance(payload, str)
    if name == "integer":
        return isinstance(payload, int) and not isinstance(payload, bool)
    if name == "number":
        return isinstance(payload, (int, float)) and not isinstance(payload, bool)
    if name == "boolean":
        return isinstance(payload, bool)
    if name == "null":
        return payload is None
    raise SchemaError(f"unsupported schema type {name!r}")


def load_schema(path: Path = SCHEMA_PATH) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def _parse_weight(text: str) -> tuple[str, float]:
    pattern, _, factor = text.rpartition("=")
    if not pattern:
        raise argparse.ArgumentTypeError("weight must be given as GLOB=FACTOR")
    try:
        return pattern, float(factor)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid weight factor: {factor!r}") from exc


def _parse_metadata(text: str) -> tuple[str, str]:
    key, separator, value = text.partition("=")
    if not separator or not key:
        raise argparse.ArgumentTypeError("metadata must be given as KEY=VALUE")
    return key, value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Emit a spec/power-trace.schema.json trace of per-cycle switching "
            "activity (a PROXY for dynamic power, not watts) from a simulator VCD."
        )
    )
    parser.add_argument("--vcd", required=True, type=Path, help="input VCD file")
    parser.add_argument("--out", required=True, type=Path, help="output trace JSON path")
    parser.add_argument("--summary", action="store_true", help="print a human-readable summary")
    parser.add_argument("--clock", default="clk", help="clock signal name or full path")
    parser.add_argument(
        "--scope",
        action="append",
        default=[],
        help="restrict tracked signals to this hierarchical scope (repeatable)",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="glob of signal paths to exclude from the activity proxy (repeatable)",
    )
    parser.add_argument(
        "--weight",
        action="append",
        default=[],
        type=_parse_weight,
        help="per-signal weight as GLOB=FACTOR (repeatable, default 1.0)",
    )
    parser.add_argument(
        "--count-aliases",
        action="store_true",
        help="count every $var declaration instead of one per unique identifier",
    )
    parser.add_argument("--reset", default="rst_n", help="reset signal name ('' to disable)")
    parser.add_argument(
        "--reset-active-high",
        action="store_true",
        help="treat the reset signal as active high (default active low)",
    )
    parser.add_argument("--busy", default="busy", help="busy signal name ('' to disable)")
    parser.add_argument("--modulus", default="modulus", help="modulus signal name ('' to disable)")
    parser.add_argument("--fault", default="", help="fault signal name (optional)")
    parser.add_argument("--kem-modulus", type=int, default=3329)
    parser.add_argument("--dsa-modulus", type=int, default=8380417)
    parser.add_argument(
        "--default-active-state",
        default="kem",
        choices=["kem", "dsa", "dma"],
        help="state for busy cycles whose modulus matches neither parameter set",
    )
    parser.add_argument("--hardware-id", default="lca_modmul-rtl-sim")
    parser.add_argument("--operation", default="modmul")
    parser.add_argument("--workload", default="single constant-iteration modular multiply")
    parser.add_argument(
        "--metadata",
        action="append",
        default=[],
        type=_parse_metadata,
        help="extra KEY=VALUE recorded under metadata.operation_parameters (repeatable)",
    )
    parser.add_argument(
        "--no-tool-probe",
        action="store_true",
        help="skip git/simulator version probing (offline or hermetic runs)",
    )
    return parser


def generate(args: argparse.Namespace) -> tuple[PowerTrace, dict[str, Any]]:
    vcd = parse_vcd(args.vcd)
    clock_ident = resolve_signal(vcd, args.clock)
    if clock_ident is None:
        raise VcdError("a clock signal is required")
    clock_paths = sorted({var.path for var in vcd.variables if var.ident == clock_ident})

    rules = StateRules(
        reset_ident=resolve_signal(vcd, args.reset or None),
        reset_active_low=not args.reset_active_high,
        busy_ident=resolve_signal(vcd, args.busy or None),
        modulus_ident=resolve_signal(vcd, args.modulus or None),
        fault_ident=resolve_signal(vcd, args.fault or None),
        kem_modulus=args.kem_modulus,
        dsa_modulus=args.dsa_modulus,
        default_active_state=args.default_active_state,
    )

    tracked, skipped = select_signals(
        vcd,
        scopes=args.scope,
        excludes=args.exclude,
        weights=args.weight,
        exclude_idents={clock_ident},
        count_aliases=args.count_aliases,
    )
    samples = compute_cycle_activity(vcd, tracked, clock_ident, rules)
    trace = build_trace(
        vcd=vcd,
        vcd_path=Path(args.vcd),
        samples=samples,
        tracked=tracked,
        skipped=skipped,
        clock_path=clock_paths[0] if clock_paths else args.clock,
        hardware_id=args.hardware_id,
        operation=args.operation,
        workload=args.workload,
        extra_metadata=dict(args.metadata),
        probe_tools=not args.no_tool_probe,
    )
    payload = trace_payload(trace)
    validate_against_schema(payload, load_schema())
    return trace, payload


def summarise(trace: PowerTrace) -> str:
    proxy = trace.metadata["activity_proxy"]
    per_cycle = proxy["per_cycle"]
    states: dict[str, int] = {}
    for sample in trace.samples:
        states[sample.state] = states.get(sample.state, 0) + 1
    peak_index = max(range(len(per_cycle)), key=per_cycle.__getitem__)
    lines = [
        f"samples (clock cycles) : {len(trace.samples)}",
        f"clock                  : {trace.metadata['clock_hz'] / 1e6:.3f} MHz "
        f"({trace.metadata['sample_interval_ns']} ns sample interval)",
        f"tracked signals        : {proxy['tracked_signal_count']}",
        f"activity proxy total   : {proxy['total']:.1f} weighted toggles",
        f"activity proxy mean    : {proxy['mean']:.3f} per cycle",
        f"activity proxy peak    : {proxy['max']:.1f} at sample {peak_index} "
        f"(t={trace.samples[peak_index].timestamp_ns} ns)",
        "state histogram        : "
        + ", ".join(f"{name}={count}" for name, count in sorted(states.items())),
        "watts                  : none (estimated_watts and measured_watts are null)",
        "NOTE                   : toggle counts are a PROXY for switching activity,",
        "                         not a power measurement. See docs/LEAKAGE_METHODOLOGY.md.",
    ]
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        trace, _ = generate(args)
    except (VcdError, SchemaError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    trace.to_json(args.out)
    if args.summary:
        print(f"trace                  : {args.out}")
        print(summarise(trace))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
