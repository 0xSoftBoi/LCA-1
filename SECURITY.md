# Security policy

## Current support boundary

LCA-1 has no production-ready or security-certified release. The implemented
v0 slice is research and verification infrastructure for a modular arithmetic
primitive. It must not protect production keys or authorize bridge value.

Security review currently covers the latest `main` branch. Older commits and
generated artifacts are not maintained as supported security releases.

## Reporting a vulnerability

Use GitHub's private **Report a vulnerability** flow for this repository. If
that flow is unavailable, contact the repository owner through an established
private channel before disclosing exploit details. Do not put secrets, private
keys, traces containing sensitive material, or an unpatched exploit in a
public issue.

Include the affected commit, threat model, reproducible steps, observed versus
expected behavior, impact, and any proposed mitigation. Receipt does not imply
a fixed response or remediation deadline; severity and disclosure timing are
coordinated after reproduction.

## In scope

- arithmetic or protocol correctness and fail-open behavior;
- data-dependent latency/control, response instability, or reset persistence;
- build, generated-evidence, dependency, or provenance compromise;
- future secret-memory, zeroization, DMA, driver, and physical attack paths.

## Explicit non-claims

Passing CI or formal checks does not establish complete algorithm correctness,
constant-power behavior, physical attack resistance, secure key storage, FIPS
140-3 validation, or production suitability. See `spec/THREAT_MODEL.md` and
`spec/VERIFICATION_PLAN.md`.
