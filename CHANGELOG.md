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

### Boundaries

- The license grant covers first-party files only; submodules and derived
  material keep their own terms (`NOTICE`). Export/public-release posture
  review remains tracked in
  [SUW-263](https://linear.app/suwappu/issue/SUW-263).
- Full ML-KEM/ML-DSA datapaths, named-target PPA, end-to-end acceleration,
  physical security, certification, and production readiness remain deferred.
