<!-- SPDX-License-Identifier: Apache-2.0 -->

# LCA-1 pre-silicon status

Status date: 2026-08-24

This is the authoritative short-form checkpoint for the repository. It separates work that has executable evidence from work that still depends on physical implementation, vendor acceptance, or silicon. It does not supersede `GOAL.md`, `fabrication/rev_a_release.json`, or the detailed verification plan.

## Closed in the repository

- The v0 dual-modulus arithmetic slice remains the characterized reference and regression anchor.
- The deterministic butterfly corpus now covers canonical data plus a family of invalid residues across every operand position and both supported moduli. The concrete `q+2048` mutation witness and the top of the 24-bit input space are included.
- The fail-closed formal harness quantifies over the complete invalid 24-bit request space rather than one fixed malformed request.
- The Rev-A NTT controller no longer models reset/zeroization as a single-cycle clear of 256 words. Explicit zeroization is a bounded 256-cycle scrub, blocks new starts, and does not retrigger forever when the top-level request is held high.
- ML-DSA inverse-NTT subtraction is explicitly materialized at signed 32-bit width before multiplication, matching the pinned PQClean C expression instead of relying on SystemVerilog context sizing.
- CI directly compiles and runs an NTT zeroize/recovery protocol regression and independently elaborates the NTT with the pinned repository-local Yosys runtime.
- The optional Verilator cross-check now treats inability to elaborate the Rev-A NTT as a failure whenever Verilator is present.
- Supply-chain CI exposes vector, fabrication-contract, fabrication-artifact, SBOM, and end-to-end reproducibility gates as separate steps so a drift failure is attributable.
- The stale pre-fabrication documentation PR was closed rather than merged over newer Rev-A evidence.

## Deliberately not claimed closed

The following remain real gates, not documentation tasks:

1. **NTT coefficient SRAM architecture.** The current candidate still uses an internal 256x32 coefficient array. The impossible bulk clear is gone, but a conflict-free SRAM banking/scheduling design has not yet been selected and characterized.
2. **NTT pipeline/PPA.** The candidate still performs a full butterfly combinationally in one cycle. It has not earned a SKY130 timing/area/power claim.
3. **OpenFrame Rev-A wrapper.** The fabrication contract pins the shell boundary, but the final bounded accelerator-only wrapper, macro binding, precheck, and route closure are not complete.
4. **SRAM macro selection.** OpenRAM, SRAM22, and the commercial ChipFoundry macro remain evidence-gated; no option is selected by this checkpoint.
5. **Physical signoff.** DRC/LVS on prior hardening experiments is evidence, not Rev-A top-level signoff. STA, IR/EM, DFT, package, and ATE closure remain open.
6. **Vendor/foundry acceptance and commercial authorization.** No reservation, contract, paid macro license, restricted access, mask release, or external shipment is authorized by repository work.
7. **Silicon evidence.** Packaged parts, bench characterization, pilot appliances, independent evaluation, and the Rev-B decision cannot be completed pre-silicon.

## Merge rule for the current closure branch

The branch may merge only when both repository workflows are green at the same head commit. In particular:

- generated corpus drift must pass;
- the fabrication contract and generated package/ATE artifacts must remain current;
- SBOM and end-to-end reproducibility must pass;
- model/unit tests, RTL regression, NTT protocol regression, formal gates, and generic synthesis must pass;
- license compliance must pass.

A green merge means **the measured repository blockers addressed by this branch are closed**. It does not mean the LCA-1 program or the `GOAL.md` silicon outcome is complete.
