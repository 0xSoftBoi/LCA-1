# /goal — LCA-1 Phase 0/1

## Outcome

Turn LCA-1 from a name into an executable, falsifiable architecture program for
the Suwappu Lattice Bridge workload.

This phase is complete when the repository contains:

- [x] a pinned workload boundary derived from Entanglement Transfer Protocol;
- [x] an explicit threat model and claim boundary;
- [x] a dual-modulus architecture supporting ML-KEM-768 and ML-DSA-65 arithmetic;
- [x] a dependency-free golden model and bridge-workload accounting tool;
- [x] a constant-latency SystemVerilog modular multiplier and butterfly slice;
- [x] deterministic tests for both NIST moduli;
- [x] a power/telemetry contract that VoltForge can consume;
- [ ] measured CPU/GPU baseline data from the real ETP crypto backend;
- [ ] an FPGA synthesis and board-power report.

The first seven items are the repository-complete gate. The final two are
physical-evidence gates and cannot honestly be checked without the relevant
hardware and real ML-KEM/ML-DSA backend.

## Design decision

LCA-1 v0 is a shared lattice-arithmetic coprocessor, not an entire bridge in
silicon. It accelerates the arithmetic shared by:

- ML-KEM-768 encapsulation and decapsulation for sealed lattice keys; and
- ML-DSA-65 signing and verification for commitment and relay authentication.

The initial hardware slice is a constant-latency modular multiply/butterfly
unit. It supports both NIST moduli through one 24-bit datapath. This is the
smallest block that can be tested independently and later replicated inside an
NTT engine.

## Non-goals for this phase

- claiming a complete ML-KEM or ML-DSA hardware implementation;
- claiming FIPS 140-3 validation or CMVP status;
- publishing speedup, power, area, or frequency numbers without artifacts;
- replacing ETP's protocol, bridge validation, key policy, or host software;
- treating a kernel benchmark as an end-to-end bridge result.

## Next physical gate

Run the pinned real-crypto ETP workload, capture primitive and end-to-end traces,
synthesize the RTL on a named FPGA, and measure joules per completed bridge
operation. Only then select lane count, SRAM size, Keccak integration, and a
candidate ASIC process.
