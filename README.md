# LCA-1

[![verification](https://github.com/0xSoftBoi/LCA-1/actions/workflows/ci.yml/badge.svg)](https://github.com/0xSoftBoi/LCA-1/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
[![REUSE status](https://api.reuse.software/badge/github.com/0xSoftBoi/LCA-1)](https://api.reuse.software/info/github.com/0xSoftBoi/LCA-1)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/0xSoftBoi/LCA-1/badge)](https://scorecard.dev/viewer/?uri=github.com/0xSoftBoi/LCA-1)
[![Cite this repository](https://img.shields.io/badge/cite-CITATION.cff-green.svg)](CITATION.cff)

> **Status: E1 evidence plus a Rev-A fabrication/package contract in review.**
> This repository has an auditable arithmetic slice, generated differential
> regression, bounded formal checks, generic synthesis, and a machine-checked
> OpenFrame/QFN release contract. It still has no Rev-A RTL freeze, hardened
> user-area GDSII, target PPA, vendor acceptance, fabricated silicon, physical-
> security evidence, FIPS 140-3 validation, or production-readiness decision.

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
| Rev-A manufacturing contract | pinned OpenFrame route, complete 64-QFN table, all 44 logical GPIOs, pad modes, SRAM variants, assembly blockers, and 11 stable package/ATE/characterization tests |

The generic cell count is a regression signal, not FPGA or ASIC area. The
formal scope is deliberately narrower than full algorithm or physical-security
assurance; see `spec/VERIFICATION_PLAN.md`.

## Rev-A fabrication work

The Rev-A proposal is an accelerator-only SKY130 OpenFrame user project. It
removes the earlier PicoRV32, firmware ROM, 512 KiB SRAM, and whole-message
frontend. The baseline uses 32 KiB of compiled SRAM; a 64 KiB option remains a
separately measured experiment. The host owns complete algorithms, keys,
protocol policy, bridge state, and chain execution.

Start manufacturing review with:

1. [`docs/REV_A_INTEGRATION.md`](docs/REV_A_INTEGRATION.md) - exact cut-list,
   LCA-LINK-16 cycle contract, CSR/stream boundary, and reset/zeroize semantics;
2. [`docs/FABRICATION_AND_PACKAGE.md`](docs/FABRICATION_AND_PACKAGE.md) - route,
   64-QFN/package disposition, assembly package, ATE flow, and external gates;
3. [`fabrication/rev_a_release.json`](fabrication/rev_a_release.json) -
   machine-readable release and evidence state;
4. [`fabrication/rev_a_package.json`](fabrication/rev_a_package.json) - complete
   physical/logical pin map, pad policy, board defaults, tests, and blockers.

Validate the source manifests and generated manufacturing tables with:

```bash
make fabrication-check
```

The package map is deliberately provisional: the pinned OpenFrame datasheet's
Figure 2 maps pin 31 to `gpio[0]` and pin 38 to `vssa1`, while a later text row
mistakenly includes pin 31 under `vssa1`. ChipFoundry confirmation and a current
controlled package drawing are explicit freeze gates.

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
make test-python       # model, workload, fabrication, and power-contract tests
make vectors-check    # regenerate in memory and detect corpus drift
make rtl-test         # 280 full-width vectors plus reset/recovery
make fabrication-check # release, RTL cut-list, package, GPIO, and generated CSVs
make formal           # three bounded SAT proofs
make synth            # generic structural synthesis artifacts
```

CI uses immutable action commits, records tool versions, and retains the
`reports/` evidence bundle for 30 days for each run.

## Repository map

```text
spec/          workload, requirements, architecture, threat, interface, acceptance, power
model/         bit-exact arithmetic and power-contract reference code
bench/         ETP workload accounting and real-backend manifest gate
rtl/           synthesizable v0 arithmetic slice and Rev-A source candidates
fabrication/   Rev-A release, package/pin/ATE contracts, schemas, generated tables
verification/  generated corpus, format, and SystemVerilog regression
formal/        bounded proof harnesses and Yosys SAT script
synth/         generic structural synthesis script and claim boundary
tools/         corpus, manufacturing-artifact, validation, and pinned Yosys tools
tests/         Python deterministic, randomized, and manufacturing-contract tests
```

Start with:

1. `GOAL.md` - the persistent program goal and earned/open gates;
2. `docs/REV_A_INTEGRATION.md` - the proposed silicon boundary and shell ABI;
3. `docs/FABRICATION_AND_PACKAGE.md` - the foundry/package handoff state;
4. `spec/REQUIREMENTS.md` - exact E1 requirements and traceability;
5. `spec/VERIFICATION_PLAN.md` - evidence layers and proof limits;
6. `spec/THREAT_MODEL.md` - adversaries, controls, and security non-claims;
7. `spec/ACCEPTANCE.md` - publication and physical-evidence gates;
8. `docs/REFERENCES.md` - the standards, literature, and tooling the design
   traces to;
9. `docs/RELATED_WORK.md` - the surveyed PQC-hardware landscape and the
   narrower position this program defends;
10. `docs/IMPROVEMENT_PLAN.md` - the artifact-backed, per-layer improvement
    backlog with sequencing and donor-license audit.

## License, adoption, and citation

First-party code is licensed under [Apache-2.0](LICENSE), chosen for its
explicit patent grant so integrators, foundry partners, and commercial
adopters can evaluate and build on this work without a separate agreement.
Third-party and derived material (PQClean-derived FIPS 202 code, the PQClean
and PicoRV32 submodules) keeps its own terms, inventoried in [NOTICE](NOTICE).
Contributions follow inbound = outbound with DCO sign-off; see
[CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

The license is a copyright/patent grant, not a fitness claim: the security and
production boundaries in `SECURITY.md` and `spec/THREAT_MODEL.md` still apply
to every use.

For academic use, cite via [`CITATION.cff`](CITATION.cff) (GitHub's "Cite this
repository") and pin the exact commit, since every claim here is bounded per
commit.

The execution roadmap lives in the
[LCA-1 / Suwappu S0 Linear project](https://linear.app/suwappu/project/lca-1-suwappu-s0-trust-and-bridge-hardware-b1620d4fb616).
T0 freezes the boundary; T1/T2 close memory and OpenFrame hardening; T3-T6
close commercial, signoff, package, and vendor acceptance; T7 characterizes
first silicon before any product claim.

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

No "x faster," energy, area, frequency, production-security, certification,
TEE, private-inference, or tapeout claim belongs here without a reproducible
artifact for the exact system boundary.
