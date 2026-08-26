# Changelog

All notable changes are recorded here. Versions follow `VERSIONING.md`.

## Unreleased

### Added

- E1 requirements-to-evidence traceability and verification plan.
- Deterministic 280-case full-width RTL corpus with drift detection,
  backpressure, malformed-input, exact-latency, and reset checks.
- Reduced-width exhaustive arithmetic proof plus full-width protocol and
  fail-closed formal checks.
- Lockfile-pinned Yosys 0.68 runner, generic synthesis script, CI evidence
  artifacts, immutable action references, and Dependabot policy.
- Security, support, contribution, ownership, versioning, and pull request
  controls.
- Apache-2.0 license, `NOTICE` third-party inventory, and
  `SPDX-License-Identifier` headers on all first-party sources; PQClean-derived
  FIPS 202 files marked CC0-1.0 with provenance.
- `CITATION.cff` citation metadata, `docs/REFERENCES.md` bibliography
  (normative standards, algorithm and arithmetic literature, implementation
  baselines, tooling), Contributor Covenant 2.1 code of conduct, and
  DCO sign-off policy in `CONTRIBUTING.md`.
- REUSE 3.3 compliance (`REUSE.toml`, `LICENSES/`, pinned `reuse lint` CI job,
  `make reuse-lint`) so every file carries machine-readable license and
  copyright information.
- OpenSSF Scorecard workflow (commit-pinned, minimal permissions) and README
  badges for REUSE and Scorecard status.
- Issue templates: a defect report requiring the affected commit and a
  reproduction command, and a claim-boundary report for statements that
  exceed their evidence.
- Unbounded temporal-induction proofs of the arithmetic slice's protocol
  invariants (handshake safety, counter bound, response/fault stability)
  with all inputs unconstrained, embedded in the RTL under `ifdef FORMAL`
  and run by `make formal` alongside the three bounded proofs.
- External-oracle test layer: committed C2SP/CCTV ML-KEM-768 intermediate
  values (CC0-1.0, provenance and source hash recorded) checked against a
  forward/inverse NTT built solely from the modeled butterfly, plus
  independent FIPS 203/204 re-derivation of all 384 zeta ROM entries -
  the Python model and PQClean pin are no longer the only oracles.
- MCY mutation-coverage project for the arithmetic slice
  (`verification/mutation/`) with a pinned nightly workflow; reported kill
  ratio is a monitored lower-bound signal, not an E1 gate.
- Five supply-chain tiers improved in parallel, with three results that
  contradicted this repository's own prior claims and are recorded as
  corrections rather than quietly dropped:
  - **Verification.** Mutation campaign gains a two-engine formal
    equivalence filter (ABC `dsec` on a post-reset miter, falling back to
    Yosys `equiv_induct`); the mutation seed is now pinned, so the prior
    94.50% — produced with an unpinned wall-clock seed — was not
    reproducible and is superseded by **96.32% (183/190)** with 10
    proven-equivalent mutants excluded. It found a real gap: the
    fail-closed canonical check is exercised at exactly one out-of-range
    value per operand across the corpus *and*
    `lca_butterfly_fault_formal.sv` at once. Verilator added as a second
    front-end; it reports `BLKLOOPINIT` errors that prevent
    `lca_ntt_accel.sv` from elaborating at all, and a 64-bit-versus-int32
    context-width divergence from the PQClean reference.
  - **Characterization.** The power contract is executable: a VCD-driven
    per-cycle activity-trace generator (600 traces, all schema-valid) and
    a TVLA harness. Measured and published: **leakage detected, max
    |t| = 40.33**, 20 of 33 sample points over threshold, because
    `product_next` is conditionally accumulated on `multiplier[0]` — so
    constant-*iteration* timing does not make switching activity constant.
  - **Arithmetic.** `rtl/lca_modmul_fast.sv`, a 2-cycle constant-time
    K2-RED/Solinas multiplier registered in the Rev-A contract as a
    candidate outside the E1 chain, with q=3329 correctness proven
    **exhaustively over all 16,777,216 products** and a 1-inductive
    protocol proof.
  - **Memory.** LEF-derived 32/64 KiB fit evidence. This **disproved
    §4 of the improvement plan**: only four OpenRAM macros ship, so a
    32 KiB bank is 16 × 2 kB = 4.553 mm², **3.40×** the commercial macro,
    and the ISCAS 2023 silicon lineage covers only the 1 KiB part. The
    blocker is not closed and no option is selected.
  - **Provenance.** CycloneDX 1.6 SBOM over 27 components spanning
    software, submodule gitlinks, hardware IP and toolchain; a
    reproducibility harness; and SLSA build provenance.
- Hardening constraint sweep at 10/13/14 ns: the v0 slice **does not
  close** at any target, and relaxing the constraint lengthens the
  achieved path (13.24 → 14.19 → 14.96 ns) while power falls, because the
  optimizer trades timing for power. Honest v0 figure: ≈13.24 ns
  worst-corner (≈75 MHz) achieved but not met.
- Nightly mutation workflow timeout raised 45 → 120 minutes; the measured
  campaign takes ~52 minutes on four cores and would have timed out.
- `docs/DEPIN_LANDSCAPE.md`: primary-source survey of the DePIN market —
  device-identity and secure-element practice, confidential-compute
  attestation patterns, hardware maker programs, and post-quantum posture
  across the chains these networks settle on. Records an explicitly
  **negative** near-term assessment of the market for hardware PQC
  acceleration, the non-claims that follow from it, the one structural
  problem the evidence does support (non-rotatable classical device keys in
  decade-lifetime infrastructure), and falsifiable triggers that would change
  the conclusion.
- `docs/IMPROVEMENT_PLAN.md`: per-layer improvement backlog sourced from
  papers and tools with public code and benchmarks — faster proven
  reductions beside the shift-add slice, SRAM-backed NTT coefficients,
  MCY mutation testing, SymbiYosys k-induction, ACVP/CCTV external oracles,
  LibreLane hardening, an executable per-cycle power/TVLA flow, and a
  donor-code license audit (GPL Keccak donor and Fault's non-commercial
  ATPG engines flagged).
- `docs/RELATED_WORK.md`: sourced August 2026 survey of academic,
  open-source, and commercial ML-KEM/ML-DSA hardware; records that the
  efabless-to-ChipFoundry operator transition left the OpenFrame route live
  with scheduled 2026 shuttles, that the pinned PQClean oracle was archived
  read-only on 2026-08-04 (pin unaffected; successor projects named for any
  future oracle refresh), and the narrower positioning the evidence
  supports.
- `docs/S0_PRODUCT_BRIEF.md`: the Suwappu S0 product definition written to the
  completeness a shipping hardware product page publishes — positioning,
  composed architecture, specification tables, host-software story, security
  model, non-claims, applications, ecosystem, availability, compliance and
  support, and an FAQ. Every specification line is tagged EARNED, TARGET, OPEN
  or TBD, and a publication gate register maps each unearned line to the T0-T7
  silicon gate, A0-A11 claim gate, or P0-P2 program gate that would earn it.
  No figure is stated for die area, frequency, power or throughput, because
  none is measured.

### Fixed

- `docs/REFERENCES.md`: the Longa–Naehrig CANS 2016 DOI pointed at a
  different paper in the same LNCS volume; corrected to
  `10.1007/978-3-319-48965-0_8` (all other entries verified against
  Crossref/DOI/NIST records).

### Boundaries

- The license grant covers first-party files only; submodules and derived
  material keep their own terms (`NOTICE`). Export/public-release posture
  review remains tracked in
  [SUW-263](https://linear.app/suwappu/issue/SUW-263).
- Full ML-KEM/ML-DSA datapaths, named-target PPA, end-to-end acceleration,
  physical security, certification, and production readiness remain deferred.
