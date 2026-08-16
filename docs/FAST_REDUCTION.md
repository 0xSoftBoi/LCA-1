<!-- SPDX-License-Identifier: Apache-2.0 -->

# Fast branch-free modular reduction (`lca_modmul_fast`)

> **Status: outside the E1 evidence chain.** `rtl/lca_modmul_fast.sv` is a new,
> separately verified datapath that runs **beside** the claims-bearing v0
> slice. It is not referenced by `make verify`, `make formal`, `make test-rtl`,
> `spec/REQUIREMENTS.md`, `verification/vectors/`, the hardening project, or
> any Rev-A contract. `formal/prove.ys` is unchanged. Nothing in `README.md`'s
> "Verified now" table depends on this module, and no E1 claim may cite it
> until it has its own requirement IDs, generated corpus rows, and a hardening
> run. See "What is *not* verified" below.

This document records the exact arithmetic, the proven ranges, the
constant-time argument, the measured latency, and the reproduction commands
for the pipelined modular multiplier called for by
[`docs/IMPROVEMENT_PLAN.md`](IMPROVEMENT_PLAN.md) §1.

## Why

The first measured LibreLane SKY130 hardening run of the v0 slice
(`hardening/README.md`, run 31885341711 at commit `4a94379`) closed physical
signoff with zero routing/DRC/LVS errors but **missed its 10 ns constraint by
−3.237 ns worst setup slack**, i.e. a ≈13.2 ns critical path in the worst
corner. The improvement plan names the cause: the 24-bit conditional-subtract
add/double chain that the shift-add multiplier walks 24 times.

The plan's remedy is explicitly *additive*: a shallow, branch-free reduction
specialised to the two production moduli, added **beside** the shift-add slice,
which stays the bit-serial reference and regression anchor.

## Files

| File | Role |
|---|---|
| `model/fastmod.py` | dependency-free executable specification |
| `tests/test_fastmod.py` | exhaustive (ML-KEM) and randomized (ML-DSA) evidence |
| `rtl/lca_modmul_fast.sv` | synthesizable 3-stage pipeline |
| `verification/tb_lca_modmul_fast.sv` | self-checking Icarus testbench |
| `formal/lca_modmul_fast_formal.ys` | standalone unbounded induction proof |

## Interface

Same request/response style as `rtl/lca_modmul.sv`, with the 2-bit modulus
selector and the fail-closed `rsp_fault` output of `rtl/lca_butterfly.sv`:

```systemverilog
lca_modmul_fast #(.WORD_BITS(24)) u_fast (
    .clk, .rst_n,
    .req_valid, .req_ready, .req_modulus_id, .req_a, .req_b,
    .rsp_valid, .rsp_ready, .rsp_fault, .rsp_product
);
```

`req_modulus_id` is `0` for `q=3329` and `1` for `q=8380417`; any other value,
or an operand outside `[0,q)`, faults. A faulting request is accepted, forces
both operands to zero so nothing out of range enters the datapath, consumes
exactly the same number of cycles, and returns `rsp_fault=1` with
`rsp_product=0`.

## Identity 1 — ML-KEM, q = 3329 = 13·2⁸ + 1 (Proth form, K-RED / K2-RED)

Write `q = k·2^m + 1` with `k = 13`, `m = 8`. Split any integer `C` as
`C = C1·2^m + C0` with `C0 = C mod 2^m ∈ [0, 2^m)` and `C1 = ⌊C / 2^m⌋` (an
arithmetic shift, so negative `C` is handled too). Define

```
KRED(C) = k·C0 − C1
```

The identity is exact, not merely a congruence:

```
KRED(C) = k·(C − C1·2^m) − C1
        = k·C − C1·(k·2^m + 1)
        = k·C − C1·q                 ⇒   KRED(C) ≡ k·C  (mod q)
```

So each fold **scales by k = 13**. Two folds give
`K2RED(C) = KRED(KRED(C)) ≡ 169·C (mod q)`. Only shifts and adds are needed:
`13·x = (x<<3) + (x<<2) + x`.

K2-RED is therefore a Montgomery-style reduction — it returns a *scaled*
residue. Kyber hardware normally hides this by pre-scaling the twiddle table,
which is not available to a general-purpose `(a·b) mod q` unit. This design
cancels the scaling with one extra multiply by a constant:

```
X = norm(K2RED(a·b))        ≡ 169·a·b     (mod q),  X ∈ [0, q)
Y = norm(K2RED(X·1353))     ≡ 169·1353·X  (mod q),  Y ∈ [0, q)
                            ≡ 169²·1353·a·b ≡ a·b   (mod q)
```

because **169² · 1353 ≡ 1 (mod 3329)**. The constant is sparse:
`1353 = 2¹⁰ + 2⁸ + 2⁶ + 2³ + 2⁰`. The two stages are structurally identical
(`norm ∘ K2RED`), which is why the same range proof covers both.

### Proven ranges (ML-KEM)

| step | input domain | output range | status |
|---|---|---|---|
| `KRED` | `[0, 2²⁴)` | `[−65535, 3315]` | both endpoints attained; separable in `(C0,C1)`, checked at the corners |
| `KRED` | `[−65535, 3315]` | `[−12, 3571]` | **exhaustive** over all 68 851 integers in the input interval |
| `norm` | `[−12, 3571]` | `[0, 3329)` | `x+q ∈ [3317, 6900] < 3q`, so exactly two conditional subtracts; exhaustive over the input interval |
| `reduce_kem` | `[0, 2²⁴)` | `[0, 3329)` and **equal to `C mod 3329`** | **exhaustive over all 16 777 216 inputs** |

Domain safety of the second `K2RED` call: `X ≤ 3328` and
`3328 · 1353 = 4 502 784 < 2²⁴`.

Two conditional subtracts are *necessary*, not just sufficient: the largest
`norm` input reaches `3571 + q = 6900 > 2q = 6658`. This is exactly the kind of
off-by-one range bug Bertels et al. document in two previously published
reductions, which is why every bound here is machine-checked rather than
asserted in prose.

## Identity 2 — ML-DSA, q = 8380417 = 2²³ − 2¹³ + 1 (Solinas)

From the modulus form, `2²³ ≡ 2¹³ − 1 (mod q)`. Split
`C = C1·2²³ + C0` and substitute:

```
fold(C) = C0 + (C1 << 13) − C1 = C − q·C1     ⇒   fold(C) ≡ C  (mod q)
```

Again an exact integer identity. Both terms are non-negative for `C ≥ 0`, so
the hardware needs no sign handling: one shift, one add, one subtract per fold.

### Proven ranges (ML-DSA)

Four folds, then one conditional subtract. Each row is the *exact* maximum of
`fold` over the previous row's domain, computed and asserted in
`tests/test_fastmod.py::DsaRangeTests::test_fold_bound_chain`:

| step | exact worst-case output | fits under |
|---|---|---|
| input | `2⁴⁶ − 1` | `2⁴⁶ = 70 368 744 177 664` |
| fold 1 | `68 719 468 544` | `2³⁶ = 68 719 476 736` |
| fold 2 | `75 472 897` | `2²⁷ = 134 217 728` |
| fold 3 | `8 445 944` | `2²⁴ = 16 777 216` |
| fold 4 | `8 388 607` | `2²³ = 8 388 608` |

The fold-1 bound clears `2³⁶` by only 8192 — tight enough that it deserves a
machine check rather than a hand wave.

Since `8 388 607 = q + 8190 < 2q`, exactly one conditional subtract lands the
result in `[0, q)`. The canonical product domain is covered:
`(q−1)² = 70 231 372 333 056 < 2⁴⁶`.

All RTL stage signals on this path are carried at 48 bits, so the same bound
chain also holds for a completely *unconstrained* 48-bit stage input. That is
what makes the RTL output-range assertion 1-inductive (see below).

## Pipeline, latency, and throughput

Three registered stages:

| stage | ML-KEM work | ML-DSA work |
|---|---|---|
| A → `stage1` | fail-closed check, operand gating, one 24×24 multiply | same |
| B → `stage2` | `norm(K2RED(product))` | Solinas folds 1–2 |
| C → `rsp` | `×1353`, `norm(K2RED(·))` | Solinas folds 3–4, conditional subtract |

For a request accepted on clock edge *N*, `rsp_valid` asserts on edge *N+2*.
This is the same measurement convention as the `24` recorded per data vector in
`verification/vectors/butterfly_vectors.txt` for the shift-add slice
(`0` there means "same edge", which is what the fault path does).

| | `lca_modmul` (v0 slice) | `lca_modmul_fast` |
|---|---|---|
| latency, accepted → `rsp_valid` | 24 cycles | **2 cycles** |
| registered stages | 1 iterative datapath | 3 |
| throughput | 1 result / ~26 cycles (single request in flight) | **1 result / cycle** |
| latency on the fault path | 0 cycles (butterfly wrapper) | 2 cycles, identical to the data path |
| butterfly using it | ~26 cycles (the figure `docs/IMPROVEMENT_PLAN.md` §1 uses) | ~4 cycles (*estimate*: not built) |

The whole pipeline advances together (`req_ready = !rsp_valid || rsp_ready`),
so an unaccepted response stalls every stage rather than dropping work. That
keeps the latency fixed across stalls and keeps the control state small enough
to prove by induction.

**No fmax, area, or energy claim is made.** The pipeline was added because the
measured critical path is the iterated add/double chain; whether it actually
buys clock frequency on SKY130 is unmeasured until a hardening run exists for
this module.

## Constant-time argument

The claim is structural and bounded:

1. **No data-dependent iteration count.** There is no loop. Every request
   traverses the same three registered stages.
2. **No data-dependent control flow.** Every conditional in the datapath is a
   2:1 mux whose select is either a subtractor borrow bit (the conditional
   subtracts) or the *public* modulus selector. There is no early exit, no
   variable shift, and no operand-dependent enable.
3. **Faults do not leak through timing.** A rejected request takes exactly the
   same two cycles and returns zero; the only observable difference is the
   `rsp_fault` flag, which is a function of the request the caller already
   knows it sent.
4. **The Python model has the same shape**, and this is tested rather than
   asserted: `tests/test_fastmod.py::ConstantTimeStructureTests` runs each
   reduction under a line tracer and requires that wildly different inputs
   execute an identical multiset of source lines.

**This is not a side-channel claim.** No power, EM, or timing measurement of
any implementation has been taken. `spec/THREAT_MODEL.md`'s physical-security
non-claims apply unchanged.

## What is verified

All four gates below were run at the commit that introduced these files.

### 1. Python model — exhaustive for ML-KEM

```bash
python3 -m unittest tests.test_fastmod -v
```

```
Ran 28 tests in 16.896s

OK
```

The headline case,
`KemExhaustiveTests::test_reduce_kem_exhaustive_over_full_24_bit_domain`,
covers **every value in `[0, 2²⁴)`** — 16 777 216 inputs — and checks the
result against a rolling counter rather than CPython's `%`, so the loop
measures the implementation. That domain strictly contains all
`3328·3328 + 1 = 11 075 585` possible canonical ML-KEM products, hence all
`3329² = 11 082 241` canonical operand pairs.

For ML-DSA the evidence is 150 000 seeded random reduction inputs over
`[0, 2⁴⁶)`, 50 000 seeded random canonical multiplies, 64-wide windows around
eleven boundary anchors (`0`, `q`, `2q`, `2¹³`, `2²³`, `2²⁴`, `2³⁶`, `2⁴⁵`,
`(q−1)²`, `2⁴⁶`), all ordered pairs of eight edge operands, and the exact
range-bound chain above. Both moduli are additionally differentially checked
against `model.modarith.mul_mod_shift_add`, the already-verified 24-cycle
slice, on 4 000 pairs each.

### 2. RTL simulation

```bash
iverilog -g2012 -Wall -s tb_lca_modmul_fast -o /tmp/simv_fast \
    rtl/lca_modmul_fast.sv verification/tb_lca_modmul_fast.sv && vvp /tmp/simv_fast
```

```
PASS lca_modmul_fast checks=1232 latency=2 cycles stages=3 stream=256 seed=1ca1fa57
```

1 232 checks: all 64 ordered pairs of eight ML-KEM edge operands, all 100
ordered pairs of ten ML-DSA edge operands, 8 fail-closed cases (bad selector,
each operand non-canonical for each modulus, all-ones operands), 800 seeded
random vectors, a 256-request full-rate stream that verifies one in-order
result per clock, a stall-and-drain test that freezes a full pipeline for 8
cycles and then drains three responses in order (one of them a fault), and a
reset-cancellation test. Golden values come from a 64-bit multiply and the
simulator's own `%`, independent of the reduction under test. Latency is
checked on **every** case, fault cases included.

### 3. Formal — unbounded temporal induction

```bash
node --experimental-wasm-exnref tools/run_yosys.mjs -s formal/lca_modmul_fast_formal.ys
```

```
[base case 1] Solving problem with 27182 variables and 78317 clauses..
Base case for induction length 1 proven.
[induction step 1] Solving problem with 54261 variables and 156086 clauses..
Induction step proven: SUCCESS!
```

Yosys 0.68 (the version pinned in `package-lock.json`), 2.82 s. Every input is
unconstrained on every cycle and the base case starts from the zero (reset)
state, so the invariant set is 1-inductive and the properties hold at all
times, not up to a bound. Proven:

*Protocol*
- **P1** `req_ready` is exactly the pipeline-advance condition.
- **P2** an unaccepted response holds `rsp_valid` with an identical fault flag
  and product for as long as reset stays deasserted.
- **P3** back-pressure freezes every pipeline register, so a stall cannot
  drop, reorder, or corrupt an in-flight request.
- **P4** a faulting response carries a zero product — fail closed.

*Arithmetic, at full width, with every stage register unconstrained*
- **A1** the ML-KEM stage-B result is canonical for `q=3329` over the whole
  `2²⁴` product domain.
- **A2** the ML-KEM stage-C result is canonical for `q=3329` over every 12-bit
  stage-2 payload.
- **A3** the ML-DSA stage-C result is canonical for `q=8380417` over **all
  2⁴⁸** possible stage-2 payloads — the four-fold Solinas bound chain proven at
  full width by SAT, not sampled.
- **A4** the registered response product is canonical for the modulus that
  produced it.

The range assertions are written on untruncated function results (the K-RED
normalizer returns a signed 32-bit value and the ML-DSA conditional subtract
returns 48 bits) specifically so that a range assertion cannot be satisfied by
a bit-select silently discarding an out-of-range value.

### 4. Licensing

```bash
reuse lint
```

```
Congratulations! Your project is compliant with version 3.3 of the REUSE Specification :-)
```

### Structural synthesis (informational, not a claim)

```bash
node --experimental-wasm-exnref tools/run_yosys.mjs \
  -p "read_verilog -sv rtl/lca_modmul_fast.sv; hierarchy -top lca_modmul_fast; synth; stat"
```

reports `Found and reported 0 problems` and 5 588 generic cells including 107
flip-flops. At RTL level the design elaborates to six `$mul` cells: **one**
operand-by-operand multiply, four multiplies by the constant 13 (the K-RED
folds) and one by the constant 1353 — the constant ones are shift-adds. This is
a generic mapping, **not** an FPGA or ASIC area number, and it is not
comparable to the 36 697.7 µm² recorded for the hardened v0 slice.

## What is *not* verified

- **No ASIC timing, area, or power for this module.** There is no LibreLane
  SKY130 hardening run for `lca_modmul_fast`. The −3.237 ns setup slack that
  motivated the work is a measurement of the *v0 slice*, not evidence that this
  module fixes it. Until a hardening run exists, "faster" here means *fewer
  cycles*, nothing more.
- **No formal proof of arithmetic equivalence.** The formal script proves
  *range* invariants (`result ∈ [0,q)`) and protocol invariants. It does **not**
  prove `rsp_product == (a·b) mod q`. That congruence is model and simulation
  evidence: exhaustive for `q=3329`, randomized plus boundary for
  `q=8380417`. Closing this for ML-DSA would need an SMT/induction harness in
  the style of the Adams Bridge Barrett verification cited below.
- **No exhaustive RTL simulation.** The exhaustive `q=3329` argument is carried
  by `model/fastmod.py`, and the RTL is checked against it by directed,
  boundary, streaming, and 800 seeded random vectors — not by 11.1 M
  simulation cycles.
- **Not in the generated corpus.** `tools/gen_vectors.py` and
  `verification/vectors/` are untouched; there are no requirement IDs in
  `spec/REQUIREMENTS.md` for this module, no mutation-testing campaign, and no
  entry in `spec/VERIFICATION_PLAN.md`.
- **No butterfly integration.** `rtl/lca_butterfly.sv` still instantiates
  `lca_modmul`. The ~4-cycle butterfly figure above is an *estimate* from stage
  counting, not a built and measured design.
- **No side-channel claim**, per the constant-time section above.
- **`WORD_BITS` is not really parametric.** The reductions are specialised to
  the two 24-bit production moduli; the parameter exists to match the port
  style of `rtl/lca_modmul.sv` and must be 24.

## Route into the evidence chain

In dependency order, none of it done yet:

1. requirement IDs plus `spec/VERIFICATION_PLAN.md` and
   `spec/REQUIREMENTS.md` rows;
2. corpus rows from `tools/gen_vectors.py` so the module is covered by the
   deterministic regression and the mutation campaign;
3. a `make formal` block (this proof, currently standalone);
4. a LibreLane SKY130 hardening run under `hardening/`, so the fmax question
   is answered with a number and the −3.237 ns baseline gets a comparison;
5. only then, a butterfly variant that instantiates it.

## References

- Bisheh-Niasar, Azarderakhsh, Mozaffari-Kermani, *High-Speed NTT-based
  Polynomial Multiplication Accelerator for CRYSTALS-Kyber* — K-RED / K2-RED
  for Proth-form moduli: <https://eprint.iacr.org/2021/563.pdf>
- Bertels et al., *KyberButterflyCollection* — open CC0-1.0 Verilog
  butterflies with testbenches, and the documented range/correctness bugs in
  two prior published reductions that motivate machine-checking every bound
  here: <https://github.com/axytho/KyberButterflyCollection>
  (paper: <https://eprint.iacr.org/2024/1367.pdf>)
- Caliptra / Adams Bridge ML-DSA hardware — Solinas reduction for
  `q = 2²³ − 2¹³ + 1`, pipelined and constant-time:
  <https://chipsalliance.github.io/caliptra-web/docs/2.1/hardware/adams_bridge_mldsa.html>
  (RTL, Apache-2.0: <https://github.com/chipsalliance/adams-bridge>)
- SMT verification of Adams Bridge's Barrett module — the working precedent
  for closing the equivalence gap listed above:
  <https://arxiv.org/abs/2604.15249>
- Xing and Li, *A Compact Hardware Implementation of CCA-Secure Key Exchange
  Mechanism CRYSTALS-KYBER on FPGA*, TCHES 2021(2) — the Barrett variant this
  design was weighed against:
  <https://tches.iacr.org/index.php/TCHES/article/view/8797>

No third-party code was copied into this repository. The cited artifacts
informed the derivations, which were re-derived and re-proven here; the
donor-license audit in `docs/IMPROVEMENT_PLAN.md` is unaffected.
