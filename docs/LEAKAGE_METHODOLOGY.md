<!-- SPDX-License-Identifier: Apache-2.0 -->
# Pre-silicon leakage methodology and measured result

> **Result, stated first and plainly.** A fixed-vs-random TVLA over 400
> simulated activity traces of `rtl/lca_modmul.sv` **detects leakage**:
> **max |t| = 40.33** at sample 18, with **20 of 33 sample points above the
> |t| > 4.5 threshold**. The unmasked constant-iteration multiplier's
> switching activity is operand-dependent. This is the expected outcome for a
> design with no masking, and it is published as a negative result. LCA-1
> makes **no side-channel-resistance claim** and none of these numbers is a
> power measurement.

This document defines what was measured, how, what the numbers do and do not
support, and exactly what would be required to turn any of it into a real
leakage claim.

## 1. Boundary of this evidence

| Question | Answer |
|---|---|
| What is simulated? | `rtl/lca_modmul.sv`, the 24-bit constant-iteration shift/add modular multiplier, driven by `tools/power_probe_tb.sv` |
| What is measured? | Per-clock-cycle **weighted toggle count** (Hamming distance across tracked RTL signals between consecutive rising edges) |
| Is it power? | **No.** No watts, no joules, no capacitance, no voltage |
| Is it silicon? | **No.** RTL (pre-synthesis) event simulation only |
| What does it feed? | `spec/power-trace.schema.json` traces with `source = "simulator"`, `estimated_watts = null`, `measured_watts = null` |
| What is claimed? | Only that the activity proxy is input-dependent, at the stated trace count |
| What is *not* claimed? | Any power figure, any energy figure, any resistance to DPA/CPA/template attacks, any certification posture |

The design's only current side-channel control is constant-iteration timing:
the multiplier always runs exactly 24 iterations for a canonical request. That
removes a *timing* channel. It does nothing about the *switching-activity*
channel, and this measurement is the quantified evidence of that gap.

## 2. The activity proxy

### 2.1 Definition

For every rising edge of the clock, the tool takes a snapshot of all tracked
signals and computes

```
activity(cycle_n) = sum over tracked signals s of
                    weight(s) * HammingDistance( value(s, edge_{n-1}),
                                                 value(s, edge_n) )
```

`x` and `z` are ordinary symbols: a bit position counts as a transition when
the two 4-state symbols differ. Weights default to 1.0 per bit and exist only
so that a future calibration can up-weight high-capacitance nets; the measured
campaign used uniform weights, so the number is a plain toggle count.

The sample at edge *n* reports the activity of the cycle **ending** at edge
*n* and the activity state the design held **during** that cycle. The first
sample compares against the values in force immediately before the first
rising edge, so uninitialised registers count as toggling once when reset
first drives them (a fixed, input-independent offset).

### 2.2 What is tracked

`tools/power_trace_from_vcd.py --scope power_probe_tb.dut` tracks the 17
signals inside the multiplier instance: `busy`, `count`, `modulus`,
`multiplicand`, `multiplicand_next`, `multiplier`, `product`, `product_next`,
`req_a`, `req_b`, `req_modulus`, `req_ready`, `req_valid`, `rsp_product`,
`rsp_ready`, `rsp_valid`, `rst_n`. Excluded:

* the clock (it toggles identically every cycle and would only add a constant);
* `$var parameter` declarations (constants, cannot toggle);
* duplicate declarations of the same net — Icarus declares one physical net
  once per scope it appears in, and the tool counts **one entry per unique VCD
  identifier code** so a net is not multiply-counted.

### 2.3 Activity-state labelling

The contract's states are assigned from the design's own signals, not from
narration:

| Condition during the cycle | State |
|---|---|
| `rst_n == 0` | `zeroize` (reset is this slice's only register-clearing path) |
| fault signal asserted (not present in this slice) | `fault` |
| `busy == 1` and `modulus == 3329` | `kem` |
| `busy == 1` and `modulus == 8380417` | `dsa` |
| otherwise | `idle` |

`dma` is unreachable in this slice; `fault` is unreachable in `lca_modmul`
(the fault path lives in `rtl/lca_butterfly.sv`). A representative trace is
3 `zeroize` cycles, 2 `idle`, 24 `dsa` (exactly the 24 constant iterations),
then 4 `idle`.

### 2.4 Why the samples carry no watts

Schema v1.0 forbids extra sample fields, so the proxy series is carried in
`metadata.activity_proxy.per_cycle`, aligned 1:1 with `samples`, alongside
`is_power_measurement: false`, `is_power_estimate: false` and an explicit
warning string. `estimated_watts` and `measured_watts` stay `null` because the
repository has neither an estimate nor a measurement, and a fabricated
watts-per-toggle constant would be exactly the kind of unbacked number this
program refuses to publish.

Every trace also records: source commit and working-tree dirty flag (read-only
`git`), generator/Python/Icarus versions, the VCD's own `$date`/`$version`/
`$timescale` and SHA-256, workload string, operand parameters, derived clock
(100 MHz), sample interval (10 ns), and honest `null`s for voltage, ambient,
cooling and instrument bandwidth. Each emitted trace is validated against
`spec/power-trace.schema.json` before it is written.

## 3. TVLA methodology

`tools/tvla.py` implements the non-specific fixed-vs-random Test Vector
Leakage Assessment of Goodwill, Jun, Jaffe and Rohatgi [1]: a Welch two-sample
t-test computed independently at each sample point,

```
t = (mean_fixed - mean_random) / sqrt( var_fixed / n_fixed + var_random / n_random )
```

with the conventional detection threshold |t| > 4.5. Means and variances are
accumulated with Welford's online algorithm, so no sum-of-squares cancellation
occurs.

Two deliberate deviations from a naive implementation, both in the direction
of honesty:

* **Degenerate points are flagged, not clipped.** If both sets have zero
  variance at a point and different means, the statistic diverges; the tool
  reports `t: null` with `degenerate: true` and says "infinite" rather than
  inventing a finite value. (No degenerate points arose in the campaign
  below.)
* **A below-threshold verdict is never phrased as a security claim.** The
  tool's own "no leakage detected" string carries the caveat inline.

### 3.1 Null check

TVLA's own sanity check was run as well: two disjoint *random* sets against
each other. If the pipeline were biased toward detection, it would fire here
too. It does not (§4.2).

## 4. Measured result

Campaign, run on commit `2e14f887f2f428c2a9c42c35f9d4276e301f0225` (working
tree dirty: the tooling in this change set was untracked at capture time),
Icarus Verilog 12.0, Python 3.11.15, 100 MHz nominal clock, modulus
`q = 8380417` (ML-DSA-65):

* **fixed set** — 200 traces, `a = 4919183`, `b = 2718281` on every run;
* **random set** — 200 traces, operands drawn uniformly from `[0, q)`
  (`random.Random(20260815)`);
* **null-check set** — a further 200 traces from the same random stream;
* 33 sample points per trace (one per clock cycle of the operation).

### 4.1 Fixed vs random — verbatim tool output

```text
sample points          : 33
traces                 : 200 fixed / 200 random
threshold              : |t| > 4.5
points over threshold  : 20
max |t|                : 40.327 at sample 18
top sample points      :
  sample   18  t=   +40.327  mean[fixed]=70.000  mean[random]=40.005
  sample   17  t=   +37.642  mean[fixed]=67.000  mean[random]=41.230
  sample   16  t=   +27.211  mean[fixed]=65.000  mean[random]=44.460
  sample    4  t=   +15.854  mean[fixed]=64.000  mean[random]=54.320
  sample    6  t=   -15.400  mean[fixed]=36.000  mean[random]=45.810
  sample   13  t=   +14.672  mean[fixed]=53.000  mean[random]=42.480
  sample   22  t=   -14.463  mean[fixed]=29.000  mean[random]=39.475
  sample   19  t=   +13.939  mean[fixed]=50.000  mean[random]=39.330
  sample    9  t=   -13.779  mean[fixed]=34.000  mean[random]=45.015
  sample   28  t=   -13.352  mean[fixed]=31.000  mean[random]=36.015

VERDICT: LEAKAGE DETECTED: 20/33 sample points exceed |t| > 4.5 (max |t| = 40.33)
over 200 fixed and 200 random traces. The activity proxy is input-dependent;
this design makes no side-channel-resistance claim.
```

The 20 points above threshold are samples 4, 6-9, 11-22, 25, 27, 28 — i.e.
they sit inside the 24-cycle iteration window, not in the reset or idle
cycles (samples 0-3 and 29-32 are bit-identical in both sets and give t = 0
exactly).

### 4.2 Null check — verbatim tool output

```text
sample points          : 33
traces                 : 200 random-A / 200 random-B
threshold              : |t| > 4.5
points over threshold  : 0
max |t|                : 2.806 at sample 16

VERDICT: NO LEAKAGE DETECTED at |t| > 4.5: 0/33 sample points exceed the
threshold over 200 random-A and 200 random-B traces. This is a bound on what
this proxy and this trace count can see, not evidence of side-channel
resistance.
```

The pipeline does not fire on random-vs-random, so the fixed-vs-random
detection is not an artefact of the tooling.

### 4.3 Why it leaks

`lca_modmul` conditionally accumulates: `product_next = add_mod(product,
multiplicand, modulus)` is taken only when `multiplier[0]` is set, while
`multiplicand` doubles and `multiplier` shifts every cycle. The register file
is written every cycle either way — that is what makes the *timing* constant —
but the **values** written, and therefore the number of bits that flip, are a
direct function of the operands. Constant-iteration timing is not
constant-power behaviour, and the measurement above is that statement in
numbers.

### 4.4 How to read the magnitude honestly

|t| is **not** a leakage magnitude. Two properties of this setup inflate it
relative to any bench measurement:

* **The fixed set has exactly zero variance.** A noiseless simulator run with
  identical inputs produces bit-identical traces, so `var_fixed = 0` at every
  point and Welch's denominator is carried by the random set alone. Real
  measurements have thermal, quantisation and environmental noise.
* **|t| grows with sqrt(N).** With a deterministic mean offset, doubling the
  trace count multiplies |t| by about 1.41 without any change in the
  underlying physics. Quoting "max |t| = 40.33" without "at 200 + 200 traces"
  is meaningless.

The stable descriptor is the standardised effect size (mean difference over
the random set's standard deviation), which does not depend on N:

| sample | t | mean fixed | mean random | sd random | effect size |
|---|---|---|---|---|---|
| 18 | +40.33 | 70.0 | 40.01 | 10.52 | 2.85 |
| 17 | +37.64 | 67.0 | 41.23 |  9.68 | 2.66 |
| 16 | +27.21 | 65.0 | 44.46 | 10.68 | 1.92 |
| 4  | +15.85 | 64.0 | 54.32 |  8.64 | 1.12 |
| 6  | -15.40 | 36.0 | 45.81 |  9.01 | -1.09 |

Effect sizes of 1-3 standard deviations are large. The conclusion "this design
leaks in the toggle-count model" is robust; the specific number 40.33 is not a
transferable quantity.

## 5. Reproducing it

```bash
# 1. build the activity-probe bench (never modifies the functional regression)
mkdir -p reports/leakage/{fixed,random_a,random_b,vcd}
iverilog -g2012 -s power_probe_tb -o reports/leakage/probe.vvp \
    rtl/lca_modmul.sv tools/power_probe_tb.sv

# 2. one simulation per operation; one trace per simulation
vvp reports/leakage/probe.vvp +a=4919183 +b=2718281 +q=8380417 \
    +vcd=reports/leakage/vcd/run.vcd
python3 tools/power_trace_from_vcd.py \
    --vcd reports/leakage/vcd/run.vcd --out reports/leakage/fixed/0000.json \
    --scope power_probe_tb.dut \
    --operation modmul --workload "ML-DSA modulus constant-iteration modular multiply" \
    --metadata group=fixed --metadata a=4919183 --metadata b=2718281 --metadata q=8380417 \
    --summary
# ... repeat 200x for the fixed set, and 400x with operands from
#     random.Random(20260815).randrange(8380417) for random_a / random_b ...

# 3. assess
python3 tools/tvla.py --fixed reports/leakage/fixed --random reports/leakage/random_a \
    --out reports/leakage/tvla_fixed_vs_random.json --summary
python3 tools/tvla.py --fixed reports/leakage/random_a --random reports/leakage/random_b \
    --fixed-name random-A --random-name random-B \
    --out reports/leakage/tvla_null_check.json --summary
```

`reports/` is git-ignored; the campaign artefacts (600 traces plus two JSON
reports) are reproducible from the commands above rather than committed. The
capture is deterministic: the same seed and the same commit reproduce the same
traces byte for byte, which is itself a reminder that there is no measurement
noise in this pipeline.

## 6. Limitations

Every one of these is a reason the numbers above are not a power or security
result.

**The measurand**

1. A toggle count is a **proxy**, not watts. There is no unit conversion to
   energy anywhere in this flow.
2. **No capacitance model.** Every net counts the same; in silicon a clock or
   bus net can dissipate orders of magnitude more per transition than a local
   node.
3. **No glitch or hazard modelling.** Values are read once per clock edge, so
   intra-cycle transitions — a large fraction of real dynamic power and a
   documented leakage source — are invisible.
4. **No static/leakage power, no short-circuit power**, no clock tree, no
   interconnect, no I/O, no memory macro.
5. **No supply voltage, no process corner, no temperature, no IR drop.**
6. **RTL, not gates.** No standard-cell mapping, no SKY130 liberty data, no
   parasitics. Synthesis will restructure this arithmetic; the toggle profile
   of the netlist will differ from the RTL profile.
7. **Signal-selection sensitivity.** The proxy depends on which signals the
   VCD contains and which scope is tracked. Combinational "next" nets
   (`product_next`, `multiplicand_next`) are counted alongside registers; a
   different, equally defensible selection yields different absolute numbers.
   Only the input-dependence conclusion is robust to that choice.
8. **No noise.** Fixed-input traces are bit-identical, which is physically
   impossible on a bench and which distorts every variance-based statistic
   (§4.4).

**The statistics**

9. **|t| is N-dependent** and here also denominator-degenerate; treat it as a
   detector output, not a magnitude (§4.4).
10. **Multiple comparisons.** 33 simultaneous tests at a fixed 4.5 threshold;
    the threshold's usual justification assumes normality and independence
    across trace sets, neither of which is verified here.
11. **One fixed input, one modulus, one operation.** Non-specific TVLA with a
    single fixed vector explores a narrow slice of the input space; a
    different fixed vector would change which points cross.
12. **TVLA detects distinguishability, not exploitability.** It says nothing
    about how many traces an actual DPA/CPA/template attack would need, and a
    *passing* TVLA has been shown to be weak evidence of resistance —
    Whitnall and Oswald [2] show the test's inferential power is limited and
    that "passing" is neither necessary nor sufficient for security.
13. **No masking verification.** No pre-silicon masking verifier (CocoAlma,
    PROLEAD) was run, because there is no masking to verify.

**The scope**

14. Only `lca_modmul` is covered. `lca_butterfly`, the fault path, the
    zeroize path and any Rev-A shell logic are not assessed.
15. The `zeroize` label is applied to reset cycles because reset is the only
    register-clearing path in this slice; it is not evidence of a validated
    key-zeroization procedure.

## 7. Standards context

**ISO/IEC 17825:2024** (*Testing methods for the mitigation of non-invasive
attack classes against cryptographic modules*) is the standards frame in which
fixed-vs-random testing is normally cited, and it governs measurement setup,
trace counts and pass/fail interpretation for validation purposes. **Nothing
here is an ISO/IEC 17825 test.** That standard concerns physical measurement of
a real module by an accredited laboratory with controlled acquisition; this is
a pre-silicon simulation proxy produced by a script. The standard is named to
locate the methodology, not to borrow its authority. The same applies to
FIPS 140-3: `SECURITY.md` and `spec/THREAT_MODEL.md` remain the governing
non-claims.

## 8. What a real leakage claim would require

In increasing order of evidentiary weight, none of which this repository has
yet:

1. **Gate-level netlist plus parasitics.** Harden the slice through the
   SKY130 flow (`hardening/`), keep the post-route netlist and the extracted
   **SPEF**, and re-run the same stimulus on the netlist so that toggles are
   counted on real cells with real loads — including glitches, which require a
   delay-annotated (SDF) simulation.
2. **Per-cycle power, not toggles.** Feed that VCD/FST through
   [trace2power](https://github.com/antmicro/trace2power) (Apache-2.0) driving
   **OpenSTA `report_power`** per clock cycle against the SKY130 liberty data.
   That produces watts with a stated corner, at which point
   `estimated_watts` may be populated and the trace becomes a genuine
   `post-synthesis estimate` source rather than `simulator`. The SKY130 port
   of the published ASAP7 workflow is the open work item.
3. **Re-run TVLA on the power estimate** — the same `tools/tvla.py`, the same
   threshold, a physically meaningful measurand, plus a first-order CPA/DPA
   attack-success curve so the result is exploitability, not just
   distinguishability.
4. **Pre-silicon masking verification** once any countermeasure exists:
   [CocoAlma](https://github.com/IAIK/coco-alma) (Yosys-native, fits this
   flow) or [PROLEAD](https://github.com/ChairImpSec/PROLEAD) with a SKY130
   cell description.
5. **Silicon.** [ChipWhisperer](https://github.com/newaetech/chipwhisperer)
   capture on a fabricated part with the shunt placed exactly at the boundary
   the power contract defines, ambient and clock recorded, `measured_watts`
   populated, and the acquisition documented to ISO/IEC 17825 expectations.
   Only then does any statement about this design's side-channel behaviour
   become a claim about hardware.

Until step 5, the honest summary is the one at the top of this document: the
unmasked constant-iteration multiplier's simulated switching activity depends
on its operands, and nothing in LCA-1 claims otherwise.

## 9. References

1. G. Goodwill, B. Jun, J. Jaffe, P. Rohatgi. *A testing methodology for side
   channel resistance validation.* NIST Non-Invasive Attack Testing Workshop,
   2011.
   <https://www.rambus.com/wp-content/uploads/2015/08/a-testing-methodology-for-side-channel-resistance-validation.pdf>
2. C. Whitnall, E. Oswald. *A Critical Analysis of ISO 17825 ("Testing methods
   for the mitigation of non-invasive attack classes against cryptographic
   modules").* IACR ePrint 2019/1013. <https://eprint.iacr.org/2019/1013>
3. ISO/IEC 17825:2024. *Information security — Testing methods for the
   mitigation of non-invasive attack classes against cryptographic modules.*
4. Antmicro. *trace2power* and *verilog-power-analysis-workflows.*
   <https://github.com/antmicro/trace2power>
5. IEEE 1364-2005, §21.7 (Value Change Dump file format).
6. B. P. Welford. *Note on a method for calculating corrected sums of squares
   and products.* Technometrics 4(3), 1962.
7. `docs/IMPROVEMENT_PLAN.md` §6 — the backlog item this work implements;
   `spec/POWER_CONTRACT.md` and `spec/power-trace.schema.json` — the contract
   the emitted traces conform to.
