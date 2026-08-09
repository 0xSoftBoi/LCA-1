# LCA-1

> **Status: executable architecture slice, not a finished chip.** This repository
> contains a pinned workload, golden model, synthesizable dual-modulus RTL, tests,
> and a power/telemetry contract. It does not yet contain an FPGA result, tapeout,
> measured speedup, or FIPS 140-3 validation.

LCA-1 is an evidence-gated lattice-cryptography coprocessor for the
[Entanglement Transfer Protocol](https://github.com/0xSoftBoi/Entanglement-Transfer-Protocol)
(ETP) bridge path. The first hardware slice accelerates the modular arithmetic
shared by:

- ML-KEM-768 encapsulation and decapsulation of sealed lattice keys; and
- ML-DSA-65 signing and verification of commitments and relay envelopes.

The design is intentionally smaller than “the whole bridge in silicon.” Bridge
policy, finality, replay protection, routing, AEAD, Merkle operations, erasure
coding, and token execution remain host responsibilities.

## What exists now

| Artifact | Evidence |
|---|---|
| Workload boundary | ETP commit and call sites pinned in [`spec/WORKLOAD.md`](spec/WORKLOAD.md) |
| Architecture | shared 24-bit arithmetic path for `q=3329` and `q=8380417` |
| Golden model | dependency-free modular multiply, butterfly, workload accounting, and power integration |
| RTL | constant-latency shift/add modular multiplier plus butterfly wrapper |
| Verification | deterministic vectors, randomized Python differential tests, RTL vectors, and CI |
| Security boundary | fail-closed validation, constant-iteration kernel, and explicit non-claims |
| Power interface | time-domain trace schema for board/VoltForge studies |

The current `/goal` and its open physical-evidence gates are tracked in
[`GOAL.md`](GOAL.md).

## The first silicon primitive

The v0 butterfly computes:

```text
t = b × w mod q
u = a + t mod q
v = a − t mod q
```

One 24-bit shift/add multiplier runs exactly 24 iterations for every accepted
request. The request selects either the ML-KEM or ML-DSA modulus. Inputs outside
the canonical range fail closed instead of being silently reduced.

This is an executable reference for architecture decisions, not the final
high-throughput implementation. CPU/GPU profiling and named-target FPGA data
must justify lane count, SRAM banking, Barrett/Montgomery reduction, Keccak
integration, and any ASIC process choice.

## Reproduce the current evidence

```bash
make test
make rtl-test
```

`make test` runs the Python model and bridge-profile smoke test. `make rtl-test`
requires Icarus Verilog; GitHub Actions installs it and runs both NIST-modulus
vectors plus the invalid-input fault case.

The benchmark manifest deliberately refuses to report a bridge baseline unless
ETP says `real_backend_active: true`. ETP's proof-of-concept fallback is useful
for protocol development, but it is not evidence for a cryptographic accelerator.

## Repository map

```text
spec/   workload, architecture, threat model, interface, acceptance and power
model/  bit-accurate arithmetic and power-contract reference code
bench/  bridge primitive accounting and real-backend manifest gate
rtl/    synthesizable arithmetic slice and SystemVerilog testbench
tests/  deterministic and randomized Python tests
```

Start with:

1. [`spec/WORKLOAD.md`](spec/WORKLOAD.md) — what is actually being accelerated;
2. [`spec/ARCHITECTURE.md`](spec/ARCHITECTURE.md) — product boundary and block plan;
3. [`spec/THREAT_MODEL.md`](spec/THREAT_MODEL.md) — assets, adversaries, and non-claims;
4. [`spec/INTERFACE.md`](spec/INTERFACE.md) — v0 handshake and future descriptor;
5. [`spec/ACCEPTANCE.md`](spec/ACCEPTANCE.md) — what must pass before stronger claims;
6. [`spec/POWER_CONTRACT.md`](spec/POWER_CONTRACT.md) — chip-to-board telemetry contract.

## Grid to gate

LCA-1 is the compute end of one systems thesis:

- a new turbine inside a 1965 plant inherits steam, controls, protection, and grid interfaces;
- a GaN/SiC converter inherits magnetics, EMI, control, cooling, and calibration;
- a cryptographic accelerator inherits protocol, memory, software, board power, thermal, and security constraints.

The recurring question is: **where does the new component meet the inherited
system, and which interface can erase the headline gain?**

LCA-1 exports a workload-shaped power trace rather than inventing a TDP. That
trace is the contract with
[VoltForge](https://github.com/0xSoftBoi/GaN-optimization-): it can drive load-step,
regulator-efficiency, decoupling, thermal, and protection analysis from measured
accelerator behavior.

## Truth gates

No “x faster,” energy, area, frequency, production-security, or certification
claim belongs here without a reproducible artifact. The next honest gate is to
run the pinned ETP workload on its real ML-KEM/ML-DSA backend, synthesize on a
named FPGA, and measure joules per completed authenticated bridge operation.
