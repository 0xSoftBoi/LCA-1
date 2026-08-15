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
