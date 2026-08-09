# LCA-1

> **Status: E1 enterprise foundations, not an enterprise-ready chip.** This
> repository has an auditable arithmetic slice, generated differential
> regression, bounded formal checks, generic synthesis, and repository
> controls. It still has no complete ML-KEM/ML-DSA datapath, named FPGA result,
> measured speedup, physical-security evidence, FIPS 140-3 validation, or
> production-readiness decision.

LCA-1 is an evidence-gated lattice-cryptography coprocessor program for the
[Entanglement Transfer Protocol](https://github.com/0xSoftBoi/Entanglement-Transfer-Protocol)
(ETP) bridge path. The implemented v0 slice targets the modular arithmetic
shared by ML-KEM-768 and ML-DSA-65. Bridge policy, finality, replay protection,
routing, AEAD, Merkle operations, erasure coding, and token execution remain
host responsibilities.

## Verified now

| Artifact | Evidence |
|---|---|
| Workload boundary | ETP commit and primitive call sites pinned in `spec/WORKLOAD.md` |
| Golden model | 4,000 randomized modular multiplies and 4,000 butterflies across both production moduli |
| RTL | synthesizable 24-bit constant-iteration multiplier and butterfly with fail-closed canonical validation |
| Generated regression | 280 deterministic full-width cases: 272 valid, 8 malformed, response backpressure, exact latency, reset/recovery |
| Formal | exhaustive four-bit arithmetic at `q=13`; full-width latency/hold and invalid-input proofs |
| Structural synthesis | lockfile-pinned Yosys 0.68 generic mapping, zero structural problems, archived logs/statistics/netlists |
| Traceability | stable requirement IDs mapped to implementation and verification in `spec/REQUIREMENTS.md` |
| Power boundary | versioned time-domain trace contract consumed by VoltForge |

The generic cell count is a regression signal, not FPGA or ASIC area. The
formal scope is deliberately narrower than full algorithm or physical-security
assurance; see `spec/VERIFICATION_PLAN.md`.

## The implemented primitive

The v0 butterfly computes:

```text
t = b × w mod q
u = a + t mod q
v = a − t mod q
```

One shift/add multiplier runs exactly 24 iterations for each canonical request.
The request selects `q=3329` or `q=8380417`; an unsupported selector or operand
outside `[0,q)` returns a fault and zero outputs without starting arithmetic.
There is one request in flight, and a response remains stable until accepted.

## Reproduce E1 evidence

Prerequisites are Python 3.12, Node 24.14.0, npm 11.9.0, and Icarus Verilog.
Yosys is installed exactly from `package-lock.json`.

```bash
npm ci --ignore-scripts
make verify
```

Useful individual gates:

```bash
make test-python     # model, workload, and power-contract tests
make vectors-check  # regenerate in memory and detect corpus drift
make rtl-test        # 280 full-width vectors plus reset/recovery
make formal          # three bounded SAT proofs
make synth           # generic structural synthesis artifacts
```

CI uses immutable action commits, records tool versions, and retains the
`reports/` evidence bundle for 30 days for each run.

## Repository map

```text
spec/          workload, requirements, architecture, threat, interface, acceptance, power
model/         bit-exact arithmetic and power-contract reference code
bench/         ETP workload accounting and real-backend manifest gate
rtl/           synthesizable v0 arithmetic slice
verification/  generated corpus, format, and SystemVerilog regression
formal/        bounded proof harnesses and Yosys SAT script
synth/         generic structural synthesis script and claim boundary
tools/         corpus generator and pinned Yosys runner
tests/         Python deterministic and randomized tests
```

Start with:

1. `GOAL.md` — the persistent program goal and earned/open gates;
2. `spec/REQUIREMENTS.md` — exact E1 requirements and traceability;
3. `spec/VERIFICATION_PLAN.md` — evidence layers and proof limits;
4. `spec/THREAT_MODEL.md` — adversaries, controls, and security non-claims;
5. `spec/ACCEPTANCE.md` — publication and physical-evidence gates.

The execution roadmap lives in the
[LCA-1 Linear project](https://linear.app/suwappu/project/lca-1-enterprise-lattice-accelerator-b1620d4fb616).
E2 completes the cryptographic datapath; E3 closes host/FPGA integration and
measurement; E4 performs physical-security and independent production review.

## Grid to gate

LCA-1 is the compute end of one systems thesis:

- a new turbine inside a 1965 plant inherits steam, controls, protection, and grid interfaces;
- a GaN/SiC converter inherits magnetics, EMI, control, cooling, and calibration;
- a cryptographic accelerator inherits protocol, memory, software, board power, thermal, and security constraints.

The recurring question is: **where does the new component meet the inherited
system, and which interface can erase the headline gain?**

LCA-1 exports a workload-shaped power trace rather than inventing a TDP. That
trace is the contract with
[VoltForge](https://github.com/0xSoftBoi/GaN-optimization-): it can drive
load-step, regulator-efficiency, decoupling, thermal, and protection analysis
from measured accelerator behavior when physical data exists.

No “x faster,” energy, area, frequency, production-security, certification, or
tapeout claim belongs here without a reproducible artifact for the exact
system boundary.
