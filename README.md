# LCA-1

**A programmable post-quantum cryptography accelerator for bridge settlement infrastructure**

[![Maturity: pre-silicon RTL](https://img.shields.io/badge/maturity-pre--silicon_RTL-f59e0b)](#silicon-readiness)
[![Algorithms: ML-KEM-768 + ML-DSA-65](https://img.shields.io/badge/algorithms-ML--KEM--768_%7C_ML--DSA--65-2563eb)](#cryptographic-scope)
[![RTL: SystemVerilog](https://img.shields.io/badge/RTL-SystemVerilog-6b21a8)](#design-hierarchy)
[![License review required](https://img.shields.io/badge/IP_review-required-b91c1c)](#ip-and-provenance)

LCA-1 is a synthesizable, firmware-controlled system-on-chip architecture for accelerating the NIST Level 3 post-quantum operations used by the Suwappu lattice bridge. The current design integrates a small RV32 control processor, ML-KEM-768 decapsulation, ML-DSA-65 verification, Keccak-f[1600], a shared NTT/INTT engine, secure SRAM, host command transport, and explicit zeroization.

This repository is seeking an experienced ASIC implementation partner for feasibility synthesis, process selection, hardening, physical design, signoff, MPW shuttle planning, packaging, and first-silicon bring-up. It does **not** claim that the present RTL is tapeout-ready.

## Executive design summary

| Item | Current definition |
|---|---|
| Intended use | Post-quantum authentication and key establishment for bridge settlement nodes |
| Cryptography | ML-KEM-768 decapsulation; ML-DSA-65 signature verification with context |
| Security level | NIST security category 3 algorithms; implementation certification not claimed |
| Architecture | RV32 firmware controller plus memory-mapped cryptographic accelerators |
| Host interface | APB-style register plane and tagged streaming ingress/egress |
| Main compute blocks | Keccak-f[1600], shared configurable NTT/INTT, modular arithmetic |
| Sensitive storage | Dedicated on-chip SRAM with reset and software-triggered zeroization |
| RTL language | Synthesizable SystemVerilog; separate legacy/TinyTapeout Verilog demonstrator under `src/` |
| Clocking | Single synchronous functional clock in the current RTL; no generated clocks |
| Reset | Active-low external reset; reset-domain and recovery analysis still required |
| Process node | Not selected; PDK-independent RTL only |
| Target frequency | To be established by synthesis against the selected PDK and operating corners |
| PPA | No foundry-qualified area, timing, or power result yet |
| DFT | Architecture pending; scan, MBIST, JTAG, ATPG, and test-mode constraints are not complete |
| Physical status | No floorplan, CTS, routed database, extracted parasitics, DRC, LVS, IR/EM, or STA signoff |

## Why dedicated silicon

Bridge nodes repeatedly execute a narrow cryptographic workload with large polynomial transforms and sponge permutations. LCA-1 keeps policy and transaction execution on the host while moving deterministic post-quantum kernels into a bounded hardware/firmware subsystem. The intended benefits are predictable latency, lower host CPU occupancy, explicit handling of secret material, and a measurable power contract. Those benefits remain hypotheses until measured on FPGA and characterized silicon.

## Cryptographic scope

The full-chip branch implements:

- ML-KEM-768 decapsulation, including ciphertext validation and shared-secret output;
- ML-DSA-65 verification, including non-empty application context;
- Keccak-f[1600] for SHAKE-based hashing and sampling;
- shared ML-KEM and ML-DSA NTT/INTT acceleration;
- constant-schedule accelerator control where defined by the current microarchitecture;
- command completion, error reporting, bounded memory regions, and zeroization.

Protocol finality, replay protection, routing, transaction policy, AEAD, Merkle processing, erasure coding, and token execution remain host responsibilities. “NIST category 3 algorithm” is not equivalent to FIPS 140-3 validation, Common Criteria certification, or a side-channel-resistant implementation.

## Design hierarchy

```text
lca_chip_top
├── picorv32                RV32 firmware control processor
├── lca_host_frontend       APB registers, tagged streams, command mailbox
├── lca_keccak_f1600        iterative Keccak-f[1600] permutation
├── lca_ntt_accel           shared ML-KEM / ML-DSA NTT and INTT engine
├── lca_secure_sram         sensitive working-memory boundary and wipe path
└── firmware                command orchestration and algorithm integration
```

Primary implementation sources:

| Path | Purpose |
|---|---|
| `rtl/lca_chip_top.sv` | Integration, address decode, processor and accelerator interconnect |
| `rtl/lca_host_frontend.sv` | Host register/stream boundary and command lifecycle |
| `rtl/lca_keccak_f1600.sv` | Keccak permutation engine |
| `rtl/lca_ntt_accel.sv` | Transform controller and modular datapath |
| `rtl/lca_ntt_zetas.svh` | Generated transform constants |
| `rtl/lca_secure_sram.sv` | Sensitive SRAM wrapper and clearing behavior |
| `firmware/` | Bare-metal RV32 runtime and cryptographic orchestration |
| `docs/COMMAND_ABI.md` | Software-visible command and status ABI |
| `docs/ARCHITECTURE.md` | Full-chip architecture and trust boundaries |
| `docs/PHYSICAL_DESIGN.md` | Initial implementation assumptions and open physical questions |

## Interfaces and integration assumptions

The current top-level model assumes one functional clock and one asynchronous active-low reset input. The host control plane is APB-style; bulk operands use tagged ready/valid streams. Firmware and accelerator SRAM are memory-mapped inside the SoC. Exact pad ring, bus wrapper, voltage domains, isolation, retention, PLL/oscillator strategy, boot source, debug policy, and package pinout must be selected with the implementation partner.

Before synthesis handoff, the project will freeze:

1. foundry process, standard-cell and SRAM compiler choices;
2. voltage, frequency, temperature, lifetime, and duty-cycle targets;
3. top-level I/O standard, pad cells, ESD strategy, and package;
4. clock/reset architecture and all timing exceptions;
5. test access, scan, SRAM BIST/repair, boundary scan, and debug lifecycle;
6. secure boot/root-of-trust boundary and production key provisioning, if required.

## Verification evidence

The current pre-silicon evidence is functional and structural—not signoff evidence.

| Layer | Evidence on this branch | Boundary |
|---|---|---|
| Arithmetic model | Randomized differential tests across ML-KEM and ML-DSA moduli | Software reference only |
| Existing arithmetic RTL | Generated full-width regression and bounded formal properties | Primitive-level scope |
| Keccak engine | 16 randomized state comparisons | Functional simulation |
| NTT/INTT | Exact comparisons for ML-KEM and ML-DSA transforms | Functional simulation |
| Frontend | APB, stream tags, mailbox, backpressure, and zeroize tests | Behavioral interface model |
| Algorithm oracle | PQClean end-to-end interoperability and tamper cases | Host oracle, not validation lab evidence |
| Full chip | RV32 firmware boot, self-test, ML-KEM decapsulation, ML-DSA verification | RTL simulation |
| Structural synthesis | Yosys process/optimization/memory/check pass | Generic cells; no PDK, SDC, or extracted timing |

Observed simulation milestones:

- firmware image: 9,236 bytes;
- firmware self-test completion: 55,063 simulated cycles;
- ML-KEM-768 decapsulation: 3,618,151 simulated cycles with exact shared-secret match;
- ML-DSA-65 verification: 7,590,585 simulated cycles with a non-empty context.

Cycle counts describe the tested RTL configuration only. They are not frequency, throughput, energy, or silicon performance claims.

## Reproducing the evidence

Initialize pinned dependencies and use the dedicated full-chip build file:

```bash
git submodule update --init --recursive
make -f Makefile.fullchip toolcheck
make -f Makefile.fullchip test
```

The original evidence-gated arithmetic flow remains available through the root `Makefile`:

```bash
npm ci --ignore-scripts
make verify
```

See `docs/BRINGUP.md` for the simulation sequence and `docs/FULL_CHIP.md` for detailed implementation notes.

## Silicon readiness

| Gate | Status | Required closure artifact |
|---|---|---|
| Requirements and workload traceability | In progress | Frozen product requirements and verification cross-reference |
| RTL architecture | Prototype complete | Reviewed RTL freeze and interface-control documents |
| Functional verification | In progress | Coverage plan, regressions, assertions, CDC/RDC, lint, X-prop, equivalence |
| Security architecture | In progress | Threat model closure, leakage/fault requirements, independent review |
| IP/legal review | Open | Complete license manifest and commercial-use approvals |
| FPGA validation | Open | Named platform, measured latency/throughput/power and reproducible bitstream |
| Process/PDK selection | Open | Foundry, node, libraries, SRAM macros, operating corners and NDA access |
| DFT | Open | Scan/MBIST/JTAG architecture, ATPG coverage and test-time estimate |
| Physical implementation | Open | Floorplan through routed database with congestion and utilization reports |
| Signoff | Open | MCMM STA, extraction, SI, IR/EM, power, DRC, LVS, antenna and density closure |
| Package/test/bring-up | Open | Package design, ATE plan, characterization plan and evaluation board |

Tapeout authorization requires every applicable gate above to have an owner, versioned artifact, review record, and explicit pass/fail decision.

## Security engineering priorities

The current implementation is **unmasked** and has not undergone TVLA, EM analysis, laser/voltage/clock fault injection, or independent cryptographic hardware review. A production design must address secret-dependent activity at the RTL and physical levels, memory remanence, fault detection, debug disablement, lifecycle states, secure provisioning, entropy requirements, and zeroization under abnormal clock/reset/power conditions.

No claim of constant-time execution, side-channel resistance, tamper resistance, secure erasure, or certification should be inferred beyond the exact properties exercised by the repository tests.

## IP and provenance

| Component | Source | Integration form | Action before commercial tapeout |
|---|---|---|---|
| PicoRV32 | YosysHQ/picorv32, pinned commit | Git submodule / soft RTL core | Confirm license notice and configuration obligations |
| PQClean | PQClean/PQClean, pinned commit | Verification oracle and firmware-derived reference material | Complete file-level provenance and notice review |
| LCA RTL/firmware | This repository | Original implementation | Establish contributor provenance and project license |
| PDK, cells, SRAM, I/O | Not selected | Foundry/vendor collateral | Execute NDA and applicable commercial agreements |

The repository does not currently present a complete top-level license determination. This is a deliberate tapeout blocker, not an implied grant of fabrication rights.

## Requested implementation-partner engagement

We are looking for a partner who can return a written feasibility package covering:

- recommended process and MPW/shuttle options for the security, SRAM, cost, and schedule targets;
- synthesis and early floorplan results with tool/library versions and reproducible constraints;
- hard-macro, SRAM, I/O, clocking, DFT, packaging, and ATE recommendations;
- PPA estimates separated into logic, memory, clock, I/O, margin, and uncertainty;
- security-hardening implications for area, timing, power, routing, and verification;
- milestone schedule and non-recurring engineering estimate from RTL review through packaged samples;
- explicit customer-supplied versus vendor-supplied deliverables and acceptance criteria.

## Handoff package

The intended handoff will contain versioned RTL, firmware, generated constants, simulation regressions, assertions, constraints, waiver logs, IP manifest, memory/pad requirements, power intent, clock/reset specification, DFT requirements, build container/tool manifest, golden hashes, and a release checklist. GDSII/OASIS, LEF/DEF, Liberty, SPEF, SDF, UPF, ATPG patterns, signoff reports, package files, and ATE content will be added as the implementation flow earns them.

## Repository map

```text
rtl/           full-chip and arithmetic RTL
firmware/      bare-metal RV32 control firmware
test/          full-chip and accelerator simulation harnesses
verification/  generated primitive-level regression corpus
formal/        bounded proof harnesses
model/         bit-exact reference models
spec/          requirements, interfaces, threat model, acceptance gates
docs/          SoC architecture, ABI, bring-up, firmware, physical design
synth/         generic synthesis flow
tools/         generators and build utilities
third_party/   pinned external dependencies
```

## Contact

Open a GitHub issue for technical questions or implementation-partner introductions. Security-sensitive findings should follow `SECURITY.md` and must not be filed publicly.

---

**Claim discipline:** LCA-1 is presently a functional pre-silicon prototype. No statement in this repository should be interpreted as foundry acceptance, production qualification, FIPS validation, tapeout signoff, or measured silicon performance.
