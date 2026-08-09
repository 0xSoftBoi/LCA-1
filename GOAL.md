# /goal — LCA-1 enterprise hardware program

## Outcome

Turn LCA-1 from a verified arithmetic demonstrator into a deployable,
independently reviewable ML-KEM-768 / ML-DSA-65 accelerator for the pinned ETP
workload—without claiming a gate before its evidence exists.

This goal stays open until the E4 production-readiness decision. Execution and
dependencies are tracked in the
[LCA-1 Linear project](https://linear.app/suwappu/project/lca-1-enterprise-lattice-accelerator-b1620d4fb616).

## Earned gates

### Phase 0/1 — executable architecture baseline

- [x] pinned ETP workload and explicit host/accelerator boundary;
- [x] threat model and honest non-claims;
- [x] dual-modulus golden model and synthesizable v0 butterfly;
- [x] power/telemetry contract connecting LCA-1 to VoltForge.

### E1 — enterprise engineering foundations

- [x] requirement IDs and requirements-to-evidence traceability;
- [x] deterministic 280-case model-to-RTL corpus with drift detection;
- [x] exact-latency, backpressure, malformed-input, and reset RTL checks;
- [x] bounded arithmetic/protocol/fail-closed formal proofs;
- [x] lockfile-pinned generic synthesis and CI evidence artifacts;
- [x] security, ownership, contribution, support, version, and PR controls;
- [ ] owner/legal decision on license, contribution terms, and export/public-release posture ([SUW-263](https://linear.app/suwappu/issue/SUW-263)).

## Open gates

### E2 — complete cryptographic datapath

- [ ] 256-coefficient NTT/INTT engine, twiddle/address schedule, and banked SRAM;
- [ ] Keccak-f[1600], SHAKE, sampling, encoding/decoding, and packing;
- [ ] complete ML-KEM-768 and ML-DSA-65 known-answer tests;
- [ ] fail-closed command control, self-test, timeout, reset, and zeroization.

### E3 — host and physical integration

- [ ] versioned descriptor/completion ABI, AXI/DMA, driver, and runtime;
- [ ] real ETP standards-conformant crypto backend with CPU/GPU baseline;
- [ ] named FPGA P&R, closed timing, bitstream provenance, and board bring-up;
- [ ] instrumented power traces and complete authenticated-operation comparison.

### E4 — security and production qualification

- [ ] timing/power/EM leakage campaign and clock/voltage fault injection;
- [ ] reset, abort, persistence, DMA isolation, and zeroization evidence;
- [ ] reproducible signed release and evidence index;
- [ ] independent architecture/RTL/software/security review;
- [ ] explicit ship/no-ship decision with residual risk and exact claims.

## Non-negotiable publication rule

Estimates are labeled estimates; simulation is labeled simulation; generic
synthesis is not PPA; FPGA measurements name the board, tools, constraints,
instrument, and uncertainty; security and FIPS claims require their actual
independent evidence. Kernel timing is never presented as an end-to-end ETP
result.

## Next executable gate

Resolve the license/release decision, then implement the scheduled NTT/INTT
engine and a pinned real-crypto ETP baseline in parallel. Lane count, SRAM
banking, reduction pipeline, and target device remain measurement-driven.
