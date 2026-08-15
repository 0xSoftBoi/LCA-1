# Related work and positioning

Surveyed August 2026. This document places LCA-1 against the lattice-PQC
hardware landscape so the repository's claims stay honest: it names the
niches other projects already own, and states the narrower position this
program can defend with evidence. Statements below were checked against the
linked primary sources at survey time; anything we could not confirm is
marked as such. General bibliography lives in [`REFERENCES.md`](REFERENCES.md);
the reuse-decision policy lives in `GOAL.md`.

## Academic full-scheme accelerators

- **Sapphire** (Banerjee, Ukyab, Chandrakasan; TCHES 2019(4), pp. 17–61;
  [arXiv:1910.07557](https://arxiv.org/abs/1910.07557)). Configurable
  lattice crypto-processor with a RISC-V host, fabricated in TSMC 40 nm LP
  (crypto core 0.28 mm², 106k gates, 40.25 KB SRAM). Implements
  Round-2-era Frodo, NewHope, qTESLA, Kyber, and Dilithium — pre-FIPS
  parameter sets. A Python simulator is public; we found no public RTL.
  The silicon-proven configurable-lattice-processor niche is taken; the
  "open RTL on an open PDK" slot was left open.
- **RISQ-V** (Fritzmann, Sigl, Sepúlveda; TCHES 2020;
  [ePrint 2020/446](https://eprint.iacr.org/2020/446)). 29 tightly coupled
  RISC-V ISA-extension instructions for lattice arithmetic; up to 11.4×
  speedup on NewHope-class workloads from synthesis-based ASIC evaluation.
  Defines the in-pipeline alternative to LCA-1's memory-mapped slice; we
  found no tapeout claim.
- **Xing & Li** ("A Compact Hardware Implementation of CCA-Secure Key
  Exchange Mechanism CRYSTALS-KYBER on FPGA," TCHES 2021(2), pp. 328–356).
  Full CCA-secure Kyber on the smallest Artix-7 (~7.4k LUTs, 2 DSPs); the
  compactness benchmark showing how little area a complete scheme needs on
  FPGA.
- **Land, Sasdrich, Güneysu** ("A Hard Crystal," CARDIS 2021;
  [ePrint 2021/355](https://eprint.iacr.org/2021/355)) and
  **Beckwith, Nguyen, Gaj** (FPT 2021): the compact and high-performance
  poles of pre-FIPS Dilithium FPGA design. The Beckwith design is the base
  of later open ML-DSA hardware.
- **KaLi** (Aikata et al.; IEEE TCAS-I 2023;
  [ePrint 2022/1086](https://eprint.iacr.org/2022/1086)). Unified
  full-scheme Kyber+Dilithium architecture, all security levels;
  synthesis-reported 0.263 mm² at 28 nm; we found no tapeout claim.
- **ML-DSA-OSH** (KU Leuven COSIC; DATE 2026;
  [ePrint 2025/2337](https://eprint.iacr.org/2025/2337);
  [repository](https://github.com/KULeuven-COSIC/ML-DSA-OSH), MIT).
  Claims the first open-source hardware implementation of complete
  final-standard ML-DSA, all three parameter sets, based on Beckwith
  et al. Its documented Dilithium→ML-DSA migration cost is independent
  support for this program's host-owns-algorithm boundary: scheme logic
  churns; the arithmetic layer does not.
- Side-channel evaluation of lattice hardware is an active field of its own
  (e.g. Karabulut/Aysu, IEEE HOST 2021; "Breaking and Protecting the
  Crystal," [PQCrypto 2023](https://dl.acm.org/doi/10.1007/978-3-031-40003-2_25)).
  LCA-1's constant-iteration requirement and power-trace contract are
  scoped inputs to that discipline, not resistance claims.

## Open-source production-grade RTL

- **Adams Bridge** (CHIPS Alliance;
  [repository](https://github.com/chipsalliance/adams-bridge), Apache-2.0).
  Production-intent PQC IP: ML-DSA-87, with ML-KEM-1024 added in 2.0, UVM
  testbenches, and documented first-order masking on the INTT pipeline.
  Consumed by **Caliptra 2.1**
  ([caliptra-rtl](https://github.com/chipsalliance/caliptra-rtl), Apache-2.0;
  [release announcement](https://www.chipsalliance.org/news/caliptra2-1/))
  with AMD, Google, Microsoft, and NVIDIA behind it. The
  full-scheme-with-countermeasures open-RTL niche is owned here. Note that
  even this flagship is under active public side-channel scrutiny
  (a hardwear.io 2026 talk targets it by name), which supports this
  repository's view that masking claims require adversarial evidence.
- **OpenTitan** (lowRISC) takes a third route: no standalone ML-KEM/ML-DSA
  block, but hardened big-number-coprocessor (OTBN) ISA extensions with a
  direct interface to its hardened Keccak core — reported 6–9× speedups
  ([design rationale](https://lowrisc.org/news/opentitan-big-number-otbn-accelerator-hardware-extensions-for-post-quantum-cryptography-extended-design-rationale/),
  [ePrint 2024/1192](https://eprint.iacr.org/2024/1192)).
- **Software baselines.** [PQClean](https://github.com/PQClean/PQClean) —
  this repository's pinned differential-test oracle — was archived
  read-only on 4 August 2026, with maintainers pointing to the PQ Code
  Package and liboqs as successors. The pin here is deliberate and frozen,
  so the archive does not invalidate existing evidence, but any future
  oracle refresh (e.g. for final-standard ML-KEM/ML-DSA vectors) must
  re-evaluate the successor projects. [pqm4](https://github.com/mupq/pqm4)
  remains the maintained embedded benchmarking baseline and includes final
  ML-KEM/ML-DSA.

## Commercial IP

PQShield (PQPlatform-Lattice/CoPro, with a 2024 PQC test chip), Rambus
(QSE-IP-86), Synopsys (Agile PQC accelerators), and SEALSQ (QS7001 secure
MCU, launched November 2025) all ship turnkey ML-KEM/ML-DSA IP or silicon
with side-channel countermeasures and certification positioning. LCA-1 does
not compete with this class and should never imply otherwise; per `GOAL.md`,
qualified commercial IP remains the expected path for memory, I/O, OTP, and
test infrastructure in any product-grade revision.

## Standards and demand context

FIPS 203, 204, and 205 were finalized on
[13 August 2024](https://www.nist.gov/news-events/news/2024/08/nist-releases-first-3-finalized-post-quantum-encryption-standards).
NSA's [CNSA 2.0](https://media.defense.gov/2022/Sep/07/2003071836/-1/-1/0/CSI_CNSA_2.0_FAQ_.PDF)
drives the hardware market's timeline — but note it mandates ML-KEM-1024
and ML-DSA-87. LCA-1's implemented moduli (q = 3329 and q = 8380417) are
shared across all ML-KEM and ML-DSA parameter sets, so the arithmetic layer
is CNSA-2.0-compatible; the currently targeted -768/-65 workload boundary
is not itself a CNSA 2.0 deployment claim.

## Fabrication-route context

The original SKY130 community-shuttle operator, efabless, shut down in
early 2025
([reporting](https://www.eenewseurope.com/en/tiny-tapeout-hit-as-efabless-closes/)).
Its founders' successor, [ChipFoundry](https://chipfoundry.io), reinstated
SKY130 shuttles including the OpenFrame platform this repository targets;
as of August 2026 the public schedule lists active runs (e.g. CI2609,
commit 5 Aug 2026 → delivery 3 Mar 2027; CI2612, commit 8 Oct 2026 →
delivery 25 May 2027). The route in
[`FABRICATION_AND_PACKAGE.md`](FABRICATION_AND_PACKAGE.md) is therefore
live, and vendor confirmation remains an explicit freeze gate precisely
because this operator transition is recent.

## Position of LCA-1

Niches this repository must not claim, because others own them: complete
open-source ML-DSA hardware (ML-DSA-OSH), production full-scheme open RTL
with masking (Adams Bridge/Caliptra), unified full-scheme architectures
(KaLi), silicon-proven configurable lattice processors (Sapphire), the
hardened-coprocessor root-of-trust route (OpenTitan), and turnkey
certified-track IP (commercial vendors).

What this program can defend, at its current evidence level:

1. **The shared arithmetic layer as the frozen silicon boundary.** Both
   production moduli behind one constant-iteration datapath, with the
   scheme logic — which the ML-DSA-OSH migration experience shows is the
   churn-prone part — kept on the host.
2. **Evidence methodology as a first-class artifact.** Requirement-traced
   corpus, bounded formal proofs with stated limits, machine-checked
   fabrication contracts, and a versioned power-trace boundary — published
   and reproducible, where academic projects ship papers and vendors ship
   closed collateral.
3. **An open-PDK, community-shuttle target.** In this survey we found no
   PQC arithmetic project on the SKY130 community-shuttle path at all;
   subject to that search's limits, the slice this repository proposes to
   harden appears to be an unoccupied niche rather than a lagging entry in
   an occupied one.

None of this is a performance, security, or product claim; those remain
gated by `spec/ACCEPTANCE.md` and the program plan in `GOAL.md`.
