# Research-backed improvement plan

Surveyed August 2026 against published work that ships **real code and
benchmarks** — papers without artifacts informed context but do not gate
decisions here. Every number below was read from the linked source at survey
time; figures derived from this repository's own structure are labeled
*estimate*. House rules apply: nothing in this plan is a claim; each adopted
item must land with its own evidence per `spec/VERIFICATION_PLAN.md` and
`CONTRIBUTING.md`.

The repository currently contains **two arithmetic datapaths** with different
maturity, and the plan treats them separately:

- the **v0 evidence slice** (`rtl/lca_modmul.sv` + `rtl/lca_butterfly.sv`):
  24-bit, 24-cycle constant-iteration shift-add multiplier; corpus-tested,
  formally checked, synthesis-tracked — the only claims-bearing datapath;
- the **Rev-A candidate engine** (`rtl/lca_ntt_accel.sv`): one butterfly per
  clock with single-cycle signed Montgomery/Barrett reduction mirroring
  PQClean semantics, coefficients in a 256×32 flip-flop array; currently
  outside the E1 evidence chain.

## 1. Modular multiplier and reduction

**Baseline.** v0: ~24 cycles per modular multiply (constant-iteration
conditional-subtract). Rev-A candidate: full-width product plus Montgomery
reduction in one combinational cycle — likely the fmax-limiting path on
SKY130 (unmeasured until §7 lands).

**What the artifact-backed literature says.** Branch-free 1–2-cycle
reductions specialized to exactly these moduli are mature:

- q = 3329 is Proth-form (13·2⁸+1): **K-RED/K2-RED** needs only shifts and
  adds ([Bisheh-Niasar et al., ePrint 2021/563](https://eprint.iacr.org/2021/563.pdf));
  the refined **Xing–Li Barrett** costs two small multiplies with a
  branch-free fixup ([TCHES 2021(2)](https://tches.iacr.org/index.php/TCHES/article/view/8797)).
  [Bertels et al., ePrint 2024/1367](https://eprint.iacr.org/2024/1367.pdf)
  reach **49 LUTs + 1 DSP per modular multiply** (vs 90 + 1 for Xing–Li) and
  — importantly for us — document range/correctness bugs in two prior
  published reductions, which argues for proving, not trusting, any adopted
  variant. Their Verilog butterflies with testbenches are public under
  **CC0-1.0**: [KyberButterflyCollection](https://github.com/axytho/KyberButterflyCollection).
- q = 8380417 = 2²³−2¹³+1 is pseudo-Mersenne: Adams Bridge documents a
  shift-add-only constant-time **Solinas** reduction, 3-stage pipelined
  ([Caliptra ML-DSA docs](https://chipsalliance.github.io/caliptra-web/docs/2.1/hardware/adams_bridge_mldsa.html),
  RTL Apache-2.0: [adams-bridge](https://github.com/chipsalliance/adams-bridge)).
- **Plantard** arithmetic wins on fixed-width CPU multipliers
  ([Huang et al., TCHES 2022, artifact-evaluated](https://artifacts.iacr.org/tches/2022/a16/)),
  but the survey found **no artifact-backed hardware Plantard** for these
  moduli; in custom RTL the same effect comes cheaper from K-RED/Solinas.
  Its value to us is the proof template: a parametric EasyCrypt Plantard
  formalization with branch-free-by-construction codegen exists
  ([ePrint 2026/1624](https://eprint.iacr.org/2026/1624.pdf)).

**Proposed change.** Add a pipelined 1–2-cycle modular multiply
(K2-RED or Bertels-style for 3329; Solinas for 8380417) as a **new module
beside** the shift-add slice, not a replacement: the 24-cycle multiplier
stays as the bit-serial reference implementation and regression anchor.
Expected effect on the v0 butterfly: ~26 → ~3–5 cycles (*estimate*).

**Evidence work required.** New requirement IDs; corpus extension via
`tools/gen_vectors.py`; and — the decisive advantage of q = 3329 — the
reduction is **exhaustively checkable in simulation** (2²⁴ products) and
SAT-provable at full width, upgrading on the existing `formal/` pattern.
For 8380417, bounded proofs plus the published range lemmas. The
[SMT verification of Adams Bridge's own Barrett module](https://arxiv.org/abs/2604.15249)
is the working precedent.

## 2. NTT engine and coefficient memory

**Baseline.** Rev-A candidate: 1 butterfly/clock, ~896 butterflies + scale
pass per 256-point transform (*estimate ≈1.1k cycles*), coefficients in a
256×32 **flip-flop array** (~8k FFs) — an area liability on SKY130 and a
structure synthesis cannot map to SRAM.

**Verified design points per 256-point NTT** (all with linked sources):

| Design | Architecture | Cycles/NTT | Notes |
|---|---|---|---|
| [KiD](https://arxiv.org/pdf/2311.04581) 1 BFU | iterative | 2304 (Dilithium) | 724 LUT; compact floor |
| [Xing–Li](https://tches.iacr.org/index.php/TCHES/article/view/8797) | 2 BF | 448 | classic compact baseline |
| [Bisheh-Niasar](https://eprint.iacr.org/2021/563.pdf) | 2×2 CT/GS | ~256 | 798 LUT/715 FF NTT unit |
| [Adams Bridge](https://chipsalliance.github.io/caliptra-web/docs/2.1/hardware/adams_bridge_mldsa.html) | 2×2 pipelined | 312 | Apache-2.0 RTL |
| [PQShield ASHES'24](https://pqshield.com/wp-content/uploads/2024/10/High-Performance-NTT-Hardware-Accelerator-to-Support-ML-KEM-and-ML-DSA.pdf) | 8-BF2 R2MDC | 258 | no public RTL |

For context, the best Cortex-M4 software NTT is
[4,474 cycles](https://tches.iacr.org/index.php/TCHES/article/view/9833)
(Plantard); pqm4 full-scheme numbers (ML-KEM-768 decaps ≈708k cycles,
[benchmarks](https://github.com/mupq/pqm4/blob/master/benchmarks.md)) frame
the host-vs-accelerator tradeoff.

**Proposed changes, in order:**

1. **Move coefficients to the SRAM boundary** (`lca_secure_sram` interface →
   §4 macros), with the fixed conflict-free address schedule the compact
   literature documents. This is the area fix and precedes any speed work.
2. **Pipeline the existing single butterfly** (2–3 stages, registered
   reduction) to hold 1 butterfly/cycle at a realistic SKY130 clock —
   ~1.1k cycles/NTT retained, fmax recovered (*estimate; measured by §7*).
3. **Only then** consider a 2×2 unit (~256–312 cycles, 4× multiplier area,
   4-coefficients-per-word memory packing as Adams Bridge does). KaLi-style
   full unification (one 24-bit reduction = 1 Dilithium or 2 Kyber ops,
   [ePrint 2022/1086](https://eprint.iacr.org/2022/1086.pdf)) is noted but
   has no public RTL — from-paper reimplementation cost, deferred.

**Evidence work.** The engine enters the evidence chain for the first time:
requirement IDs, differential corpus at transform level, latency/schedule
formal checks, and §5's external oracle vectors.

## 3. Keccak engine

**Baseline.** 1 round/cycle, 24 cycles per f[1600] — the same design point
as OpenTitan KMAC's unmasked configuration
([theory of operation](https://opentitan.org/book/hw/ip/kmac/doc/theory_of_operation.html)).

**Findings.** pqm4 hashing fractions justify the engine: 35–65% of
ML-KEM-768/ML-DSA-65 runtime is Keccak
([pqm4 benchmarks](https://github.com/mupq/pqm4/blob/master/benchmarks.md)).
Faster-than-1-round/cycle buys little (Amdahl); the interesting directions
are **area folding** (Keccak team mid-range core: 74 cycles at 28 kGE vs
48 kGE fast core, [keccak.team](https://keccak.team/2012/mid_range_hw.html))
and **first-order DOM masking** (OpenTitan: 4 cycles/round → 96
cycles/f[1600], ~800 DOM multipliers of PRNG entropy per cycle,
entropy-stall interface, all behind one Verilog parameter, Apache-2.0).
The [TCHES 2024 area-record masked SHA-3](https://artifacts.iacr.org/tches/2024/a25/readme.html)
ships RTL, synthesis scripts, and PROLEAD/TVLA configs — the best template
for what evidence-carrying masked Keccak looks like. (Note: the Gross et al.
[keccak_dom](https://github.com/hgrosz/keccak_dom) donor is **GPL-3.0** —
incompatible with our Apache-2.0 inbound policy; use OpenTitan or the TCHES
2024 artifact instead.)

**Proposed change.** Keep 1 round/cycle. Adopt the OpenTitan-style
parameterized masking *socket* (state sharing, entropy interface) only when
a masking claim is actually scheduled; until then the honest posture is §6's
quantified unmasked leakage baseline.

## 4. Memory

**Baseline.** Behavioral SRAM model; Rev-A contract lists ChipFoundry
`CF_SRAM_8192x32` (32 KiB, 1.34 mm², $2,500/project,
[product page](https://chipfoundry.io/commercial-sram-macro)) with
commercial views not yet acquired.

**Finding — SUPERSEDED 2026-08-16, this section was wrong.** The original
text claimed [sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros)
ships "1/2/4/16 kB variants" so that "a 32 KiB bank = 2×16 kB or 8×4 kB
macros". Checking three distribution trees, including the one `open_pdks`
installs, found **four macros only**: the 4 kB and 16 kB directories carry
truncated logs and no views, and history contains a commit titled
"Comment out 8kb and 16kb". A 32 KiB OpenRAM bank is therefore **16 × 2 kB
macros**.

Corrected numbers, from verbatim LEF `SIZE` lines rather than assumption
(see [`SRAM_DECISION.md`](SRAM_DECISION.md)):

| Option | 32 KiB macro area | vs CF_SRAM | License |
|---|---|---|---|
| OpenRAM 2 kB × 16 | 4.553 mm² | **3.40×** | Apache-2.0 |
| SRAM22 8 KiB × 4 | 2.110 mm² | 1.57× | BSD-3-Clause |
| CF_SRAM_8192x32 | 1.34 mm² (vendor) | 1.00× | commercial, $2,500 |

The free path costs 3.40× the area and 30.4% of the 15 mm² user area, and
its silicon-lineage claim does **not** transfer: ISCAS 2023 measured only
the 1 KiB 32x256 macro, at 34 MHz and 1.7 V, not the 2 kB macro a bank
would use. SRAM22 is the stronger free option on area.

**Proposed change.** Run the candidate 32 KiB configurations through the §7
hardening flow and extend the decision record with measured area, achieved
clock, and LVS/precheck friction. Nine criteria are defined in
`SRAM_DECISION.md`: four satisfied, one answered negatively, four still
unmeasured. **No option is selected**, and the commercial-license blocker
in `fabrication/rev_a_release.json` is not closed by this work.

## 5. Verification stack

**Findings** (all tools verified alive and compatible):

- **[MCY](https://github.com/YosysHQ/mcy)** (YosysHQ, active Aug 2026)
  mutation-tests the netlist against our existing iverilog testbench —
  its examples literally use iverilog. It answers the one question corpus
  size and formal scope cannot: *would the 280 cases detect this bug?*
- **[SymbiYosys](https://yosyshq.readthedocs.io/projects/sby/en/latest/reference.html)**
  upgrades `formal/prove.ys` to `prove` mode (k-induction → unbounded
  latency/hold proofs), `cover` mode (anti-vacuity), and multi-engine
  racing, with near-zero porting cost for our three SVA harnesses.
- **External oracles break model circularity.** Today the Python model is
  the sole oracle. NIST's
  [ACVP-Server static JSON vectors](https://github.com/usnistgov/ACVP-Server/tree/master/gen-val/json-files)
  cover final-standard ML-KEM/ML-DSA offline, and
  [C2SP/CCTV](https://github.com/C2SP/CCTV/blob/main/ML-KEM/README.md)
  publishes **NTT-level intermediate values** (decimal coefficient dumps)
  plus negative modulus-check vectors that map directly onto our
  fail-closed validation. No source provides butterfly-level vectors — our
  generated corpus remains the only oracle at that granularity, which is a
  defensible position to state explicitly.
- **[Verilator coverage](https://verilator.org/guide/latest/exe_verilator_coverage.html)**
  (line/toggle/branch → lcov HTML in CI) diagnoses corpus blind spots and
  adds a second compiler's semantics checking; Icarus has no native
  coverage.
- **cocotb 2.0** is justified for *timing-interleaving* randomization only
  (request gaps, backpressure, mid-transaction reset); published evidence
  does not show constrained-random beating a seeded differential corpus on
  data values at this design scale
  ([survey](https://arxiv.org/pdf/2403.12812)).
- Notable negative result: [adams-bridge](https://github.com/chipsalliance/adams-bridge)
  — the closest open PQC-RTL peer — verifies with commercial UVM and has
  **no formal directory**. Our bounded proofs already lead the open-PQC
  field; MCY + k-induction extends that lead cheaply.
- Stretch: Cryptol/SAW RTL equivalence
  ([HARDENS flow](https://github.com/GaloisInc/HARDENS/blob/develop/Assurance.md))
  is the only public executable-spec→RTL path; high cost, only worth it for
  the two arithmetic leaf modules pre-tapeout.

**Proposed order:** MCY nightly job → sby port → ACVP/CCTV vectors into
`tools/gen_vectors.py` → Verilator coverage → cocotb timing harness.

## 6. Power contract and leakage evidence

**Findings.** The survey found **no published end-to-end open-PDK
side-channel leakage flow with artifacts** — the niche is open, and this
repository's versioned power-trace contract is positioned to be its first
occupant. Working building blocks:

- **[trace2power](https://github.com/antmicro/trace2power)** (Antmicro,
  Apache-2.0, Rust) + its
  [workflows repo](https://github.com/antmicro/verilog-power-analysis-workflows):
  VCD/FST → per-clock-cycle OpenSTA `report_power` scripts. Demonstrated on
  ASAP7; the SKY130 port (swap liberty/netlist) is our work item.
- **TVLA harness**: Goodwill fixed-vs-random t-tests (|t|>4.5,
  [original methodology](https://www.rambus.com/wp-content/uploads/2015/08/a-testing-methodology-for-side-channel-resistance-validation.pdf))
  documented per **ISO/IEC 17825:2024** with the
  [Whitnall–Oswald critique](https://eprint.iacr.org/2019/1013) cited as a
  methodology caveat. The unmasked core *will* fail fixed-vs-random — and
  publishing that negative result honestly is exactly this repository's
  posture: it converts "no masking claims" into quantified evidence.
- **Pre-silicon masking verifiers**, when masking arrives:
  [CocoAlma](https://github.com/IAIK/coco-alma) (Apache-2.0, Yosys-native —
  best fit for our flow) and [PROLEAD](https://github.com/ChairImpSec/PROLEAD)
  (BSD-3; needs a one-time SKY130 cell-library description; the TCHES 2024
  artifact ships worked configs).
- Post-silicon: [ChipWhisperer](https://github.com/newaetech/chipwhisperer)
  capture at the contract boundary, with the eval board's shunt placed to
  match the trace definition.

**Proposed change.** Extend `spec/POWER_CONTRACT.md` with a
`simulator`-sourced trace generator: gate-level netlist (§7) + regression
VCD → trace2power → per-cycle trace emitted in
`spec/power-trace.schema.json` format, plus a TVLA report artifact in CI.

## 7. Physical implementation flow

**Findings.**

- **[LibreLane](https://github.com/librelane/librelane)** (OpenLane 2's
  successor under FOSSi stewardship) is the maintained path; release 3.0.8
  (Aug 2026) specifically fixed **Yosys 0.68** compatibility — the exact
  version this repository pins. ChipFoundry's own
  [openlane2 fork](https://github.com/chipfoundry/openlane2) + `cf harden`
  remain the shuttle-submission path; the canonical harness template is now
  [chipfoundry/openframe_user_project](https://github.com/chipfoundry/openframe_user_project).
- QoR anchors for crypto-sized SKY130 blocks:
  [ORFS AES CI design](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts/blob/master/flow/designs/sky130hd/aes/constraint.sdc)
  (~20k cells) closes around a 3.6 ns constraint;
  a signoff-level open-flow SHA-256 reports
  [97.9 MHz / 104,585 µm²](https://www.mdpi.com/2073-431X/13/1/9).
  Expect 50–150 MHz for our datapath until measured (*inference, not a
  claim*).
- **DFT license landmine**: [AUCOHL Fault](https://github.com/AUCOHL/Fault)
  (scan insertion + ATPG, Apache-2.0) bundles **ATALANTA/PODEM engines that
  are non-commercial-only** — this must enter the reuse/license inventory
  before Rev-A commits to Fault for production DFT.
- Precheck reality: ChipFoundry's
  [mpw_precheck](https://github.com/chipfoundry/mpw_precheck) runs KLayout
  DRC + netgen LVS (Magic DRC optional).

**Proposed change.** A lockfile-pinned LibreLane hardening job (initially
manual-dispatch CI) for the arithmetic-slice macro, archiving
`metrics.json`, GDS, SDF, and STA reports into `reports/` under the same
evidence discipline as the Yosys gates — converting area/fmax/power from
"deferred" to measured, and feeding §4's SRAM comparison and §6's power
extraction. Then an OpenFrame template dry-run with `cf precheck` in CI to
validate the pinned route against the real wrapper before the next shuttle
window.

## Sequencing

Ordered by evidence-per-effort; each row lands as its own PR with its own
gates. Dependencies flow downward.

Status as of 2026-08-16: items 1–7 are **done**; what each actually
delivered, including where it contradicted this plan, is recorded below
the table.

| # | Item | Layer | Effort | Status |
|---|---|---|---|---|
| 1 | MCY mutation job (modmul, butterfly) | §5 | days | **done** — plus equivalence filter; found a real gap |
| 2 | Unbounded induction proofs | §5 | days | **done** — via Yosys `-tempinduct`, not sby (not installable) |
| 3 | ACVP + CCTV oracle vectors | §5 | days | **done** |
| 4 | LibreLane hardening CI (arith slice) | §7 | days–weeks | **done** — 3-point sweep; slice does not close |
| 5 | Per-cycle power trace + TVLA report | §6 | weeks | **done** — leakage measured and published |
| 6 | SRAM decision record (OpenRAM vs CF) | §4 | weeks | **done** — but does NOT close the blocker; see §4 |
| 7 | Fast modmul beside shift-add slice | §1 | weeks | **done** — 2 cycles, exhaustive q=3329 proof |
| 8 | NTT engine: SRAM-backed coefficients + pipelined butterfly | §2 | weeks | Rev-A engine enters evidence chain |
| 9 | Verilator coverage + cocotb timing harness | §5 | weeks | corpus blind spots; timing-interleaving defects |
| 10 | OpenFrame dry-run + precheck CI | §7 | weeks | route validated pre-shuttle |
| 11 | 2×2 butterfly, masking socket, Cryptol/SAW | §1–3,5 | months | only after 1–10 earn it |

### What items 1–7 actually returned

Three results contradicted the expectations written into this plan, and
they are the most useful output of the exercise:

1. **Item 6 did not close the SRAM blocker** — it disproved this plan's
   own premise about which OpenRAM macros exist, and the free path turned
   out to cost 3.40× the area (§4).
2. **Item 4 did not find a closing constraint.** The slice misses timing
   at 10, 13, and 14 ns, and relaxing the target makes the achieved path
   *longer* because the optimizer trades timing for power. Best achieved
   is 13.24 ns at the tightest target (`hardening/README.md`).
3. **Item 1 found a genuine verification gap, not just a number.** The
   fail-closed canonical check is exercised at exactly one out-of-range
   value per operand across the corpus *and* the formal harness
   simultaneously (`docs/MUTATION_ANALYSIS.md`).

Two follow-ups these results create, both unowned:

- **Corpus generator: emit a family of out-of-range operands** per
  modulus and operand position, replacing the hand-written invalid tuple
  in `tools/gen_vectors.py`. This is the fix for finding 3 and is
  specified in `docs/MUTATION_ANALYSIS.md`. Generated data must not be
  hand-edited, so this is a generator change.
- **`lca_ntt_accel.sv` blocks Verilator entirely** (`BLKLOOPINIT` on its
  256-entry reset loops), which is a measured blocker on item 9, and its
  line 127 evaluates `zeta_q * (a_value - b_value)` at 64 bits where the
  PQClean reference uses `int32_t` — a divergence that needs a bounds
  argument before that engine enters any evidence chain
  (`verification/lint/README.md`).

## Donor-code license compatibility

| Source | License | Compatible with Apache-2.0 inbound |
|---|---|---|
| [KyberButterflyCollection](https://github.com/axytho/KyberButterflyCollection) | CC0-1.0 | yes |
| [adams-bridge](https://github.com/chipsalliance/adams-bridge) | Apache-2.0 | yes |
| [ML-DSA-OSH](https://github.com/KULeuven-COSIC/ML-DSA-OSH) | MIT | yes (attribution) |
| [OpenTitan KMAC](https://github.com/lowRISC/opentitan) | Apache-2.0 | yes |
| [sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros) | Apache-2.0 | yes |
| [trace2power](https://github.com/antmicro/trace2power) | Apache-2.0 | yes |
| [CocoAlma](https://github.com/IAIK/coco-alma) | Apache-2.0 | yes |
| [PROLEAD](https://github.com/ChairImpSec/PROLEAD) | BSD-3-Clause | yes |
| [keccak_dom](https://github.com/hgrosz/keccak_dom) | GPL-3.0 | **no — do not vendor** |
| [Fault](https://github.com/AUCOHL/Fault) ATPG engines | non-commercial | **flag in reuse inventory** |

Any vendored code enters `NOTICE` with provenance per `CONTRIBUTING.md`.
