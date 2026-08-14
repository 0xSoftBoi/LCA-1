# /goal — Ship Suwappu S0 hardware

## Outcome

Ship a controlled pilot appliance containing working **LCA-1 Rev-A custom
silicon** and demonstrate privacy-preserving AI inference tied to Suwappu
bridge and chain state.

The target is **30 April 2028**. The date is a planning bound, not permission to
skip evidence or commit to a shuttle whose schedule has not been confirmed.

Execution, blockers, owners, dates and decision records live in the
[LCA-1 / Suwappu S0 Linear project](https://linear.app/suwappu/project/lca-1-suwappu-s0-trust-and-bridge-hardware-b1620d4fb616).
The root completion contract is
[SUW-293](https://linear.app/suwappu/issue/SUW-293/goal-ship-suwappu-s0-rev-a-silicon-private-bridge-appliance).

## Product architecture

S0 is a composed hardware system, not a claim that one open-source chip solves
confidential inference.

| Layer | Rev-A responsibility | Evidence required |
| --- | --- | --- |
| LCA-1 ASIC | ML-KEM/ML-DSA arithmetic, Keccak, bridge security acceleration, bounded SRAM, command/error handling and zeroization | foundry-accepted release, packaged-silicon KATs and characterization |
| Discrete root of trust | device identity, measured boot, counters, lifecycle/debug state and key custody | supported endorsement/attestation path and adversarial tests |
| Confidential accelerator | protected AI execution and accelerator memory | selected-SKU attestation, firmware/driver measurement and isolation evidence |
| S0 policy plane | evidence verification, measurement-bound key release, bridge/chain policy and signed receipts | pinned protocol, golden transcripts, negative vectors and independent review |
| Appliance | power, board, host, enclosure, update, recovery, test, telemetry and support | controlled BOM, manufacturing test, pilot units and external evaluation |

Rev-A silicon is intentionally a bounded engineering ASIC. It is **not** a
root of trust, complete TEE, autonomous PQC SoC, certified device, masked
implementation or competitive AI accelerator.

Rev B may integrate the trust controller, secure DMA/firewalls and licensed
high-speed I/O only after Rev-A measurements and the pilot earn that investment.

## Why this route

The open-silicon evidence does not support forking a complete confidential-AI
chip:

- OpenTitan proves open RTL, firmware and commercial-grade verification can
  reach high-volume secure silicon.
- Caliptra provides useful datacenter root-of-trust architecture, not a complete
  device TEE.
- Basilisk, Cheshire and Croc demonstrate mature-node open implementation
  flows and working silicon.
- NVDLA shipped inside proprietary NVIDIA products but is not a current,
  transformer-class product platform.
- Occamy, HammerBlade, Gemmini, PULP, Celerity, BlackParrot and OpenPiton
  provide silicon-proven architectural lessons, not a supported S0 product.
- Modern memory, PCIe/SerDes, OTP, clocking, SRAM, ESD, DFT, package and test
  paths still require qualified foundry or commercial IP.

Every reuse decision must therefore record license, governance, activity,
physical-silicon evidence, closed dependencies and inherited verification work.

## Definition of goal complete

The goal remains open until every applicable item below has immutable evidence.

### Rev-A manufacturing and silicon

- [ ] A named shuttle or foundry accepts one immutable release in writing.
- [ ] Release hashes bind RTL, generated data, netlist, constraints, PDK/IP
      versions, routed database, reports and waivers.
- [ ] Traceable packaged samples power safely and expose reliable host control.
- [ ] NTT/INTT, Keccak, ML-KEM-768 decapsulation and ML-DSA-65 verification pass.
- [ ] Reset, abort, malformed command, timeout, error and zeroization tests pass.
- [ ] Voltage/frequency/temperature, latency, throughput, power, failures and
      errata are tied to sample IDs.

### Private-inference and bridge appliance

- [ ] Client and device establish an encrypted session bound to fresh
      attestation.
- [ ] Model and session keys are released only for approved measurements and
      policy.
- [ ] Every memory, DMA and software domain where plaintext may exist is named.
- [ ] Stale/replayed evidence, relay, downgrade, debug, rollback, reset,
      component replacement and malformed DMA fail closed.
- [ ] Inference receipts bind request hash, model hash, measurement, policy,
      result hash and chain state.
- [ ] Bridge/chain proof verification and replay protection use the same
      attested policy boundary.

### Pilot product

- [ ] At least three units share a controlled BOM, signed software image,
      serialization and manufacturing-test record.
- [ ] Update, recovery, telemetry, support, vulnerability, errata and
      failure-analysis procedures exist.
- [ ] One unit is delivered to an external evaluator under an owner-approved
      written test plan.
- [ ] NRE, COGS, price, lead time, EOL, export, licensing and single-source
      risks are documented.
- [ ] Independent review issues Rev-B **GO**, **DEFER**, **PARTNER** or
      **NO-GO** with exact scope and budget.

Simulation, FPGA, generated GDS, internal signoff, wafer delivery or an
uncharacterized chip does not complete the goal.

## Execution gates

| Gate | Target | Linear epic | Exit evidence |
| --- | --- | --- | --- |
| P0 — product and trust freeze | 30 Sep 2026 | [SUW-298](https://linear.app/suwappu/issue/SUW-298/s0-p0-freeze-the-sellable-product-and-composed-trust-boundary) | claims, component split, threat model, workload, reuse/IP and economic decision |
| P1 — reference appliance | 31 Jan 2027 | [SUW-300](https://linear.app/suwappu/issue/SUW-300/s0-p1-demonstrate-the-private-inference-reference-appliance) | real attestation, key release, bridge receipts, FPGA integration and adversarial benchmark |
| E1–E4 — engineering evidence | through Apr 2028 | [project](https://linear.app/suwappu/project/lca-1-suwappu-s0-trust-and-bridge-hardware-b1620d4fb616) | complete datapath, host/FPGA integration, security and independent qualification |
| T0–T6 — Rev-A silicon | through Jan 2028 | [project](https://linear.app/suwappu/project/lca-1-suwappu-s0-trust-and-bridge-hardware-b1620d4fb616) | target freeze, DFT, physical implementation, signoff, acceptance and first-silicon characterization |
| P2 — controlled pilot | 30 Apr 2028 | [SUW-299](https://linear.app/suwappu/issue/SUW-299/s0-p2-integrate-first-silicon-ship-the-controlled-pilot-decide-rev-b) | three qualified units, external evaluation and Rev-B decision |

## Critical path

1. Complete
   [SUW-296](https://linear.app/suwappu/issue/SUW-296/lca-t01-publish-the-rev-a-cut-list-and-shell-interface-contract):
   exact Rev-A cut-list and shell interface.
2. Freeze the composed S0 boundary and claims.
3. Produce mapped 32/64 KiB fit evidence and close the T0 route/legal gate.
4. Demonstrate the reference appliance on the named FPGA path.
5. Complete T1–T5 implementation, verification, DFT and signoff.
6. Obtain T6 foundry acceptance, packaged parts and characterization.
7. Integrate silicon, qualify three pilot units, run one approved external
   evaluation and issue the Rev-B decision.

Only the earliest unblocked leaf should be in progress.

## Evidence contract

Every closure artifact records:

- repository commit and generated-data hash;
- configuration and workload;
- PDK, library, macro, shell and package versions;
- tool, version, environment and exact command;
- raw logs, reports, netlists, waveforms or measurements;
- threshold and actual result;
- sample/unit ID for physical evidence;
- waiver, residual-risk owner and independent reviewer.

Screenshots and prose may summarize evidence but cannot replace it.

## Stop conditions

Issue **NO-GO**, **NEXT SHUTTLE**, **REDUCE** or **PIVOT** when:

- Rev A cannot fit with required physical margin;
- the composed attestation chain cannot support the private-inference claim;
- plaintext crosses an untrusted domain without an explicit accepted risk;
- required memory, I/O, OTP, clock, test, package or support IP is unavailable;
- cost or supply exceeds the authorized envelope;
- critical verification, physical-design, DFT, security or test ownership is
  missing;
- independent review rejects the evidence; or
- measured system value does not justify custom silicon.

An evidence-backed no-go is program success. Shipping a false security claim is
failure.

## Authority

Toma owns product scope, spend, vendor commitment, external delivery,
process/package tradeoffs, waiver acceptance and mask submission.

Nothing in this goal authorizes vendor contact, reservation, payment, agreement
acceptance, restricted-material access, waiver approval, external shipment or
mask release.
