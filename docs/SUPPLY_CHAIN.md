<!-- SPDX-License-Identifier: Apache-2.0 -->
# Supply chain, reproducibility, and provenance

This document describes what LCA-1 can currently prove about where its
artifacts came from, and — more importantly — what it cannot.

Two commitments already in the repository force this work. `GOAL.md`'s
evidence contract requires every closure artifact to record the repository
commit, generated-data hash, tool versions, and exact command. And
`docs/DEPIN_LANDSCAPE.md` section 8, item 6 records the finding that drove
the design here: **reproducible builds are the mandatory companion to any
attestation claim.** A signature over a non-reproducible artifact proves
that some machine emitted some bytes, and nothing else. So the ordering in
this repository is deliberate: reproduce first, attest second, and never
publish an attestation over an artifact that has not been re-derived in the
same run.

## Threat model

`SECURITY.md` lists "build, generated-evidence, dependency, or provenance
compromise" as in scope. That splits into four concrete adversaries.

| # | Threat | Concrete instance for LCA-1 | Control here |
|---|---|---|---|
| T1 | **Build compromise** | A tampered runner emits a netlist, corpus, or manufacturing table that no source in the repository produces. | `tools/verify_reproducible.sh` re-derives every generated artifact from committed sources and fails on any byte difference. |
| T2 | **Generated-evidence compromise** | The committed vector corpus, fabrication CSVs, or SBOM are edited by hand so a claim reads better than the source supports. | Drift gates: `gen_vectors.py --check`, `gen_fabrication_artifacts.py --check`, `gen_sbom.py --check`. Hand-editing any of them fails CI. |
| T3 | **Dependency compromise** | A mutable tag or floating version silently swaps a synthesis, simulation, or CI tool. | Every dependency the repository can pin is pinned: npm by lockfile integrity hash, submodules by gitlink SHA, GitHub Actions by full commit SHA, external repos by commit, Python tools by exact version. The SBOM enumerates all of them, and enumerates the ones that are *not* pinned. |
| T4 | **Provenance compromise** | A third party is handed an artifact and told it came from this repository at this commit, with no way to check. | `actions/attest-build-provenance` issues a SLSA v1 provenance statement, signed through Sigstore and recorded in a transparency log, binding each evidence artifact's digest to this repository, workflow, and commit. |

The adversary explicitly **not** addressed: anyone who compromises GitHub's
hosted runners or the Sigstore public-good infrastructure itself. Provenance
is a claim about which workflow produced bytes, and it inherits the trust of
whoever operated that workflow.

## What each artifact is

| Artifact | Produced by | Committed at |
|---|---|---|
| CycloneDX 1.6 SBOM | `tools/gen_sbom.py` | `docs/sbom.cdx.json` |
| Reproducibility harness | — | `tools/verify_reproducible.sh` |
| SBOM validation tests | — | `tests/test_sbom.py` |
| CI gates and attestation | — | `.github/workflows/supply-chain.yml` |

> **Path note.** The SBOM belongs next to the other release evidence, at
> `fabrication/sbom.cdx.json`. It currently lives in `docs/` because the
> change that introduced it did not own `fabrication/`. Relocating it is a
> follow-up: move the file, change `DEFAULT_OUTPUT` in `tools/gen_sbom.py`
> and the `subject-path`/artifact paths in the workflow, and regenerate.

## What the SBOM covers

`docs/sbom.cdx.json` is CycloneDX 1.6 JSON with **27 components**, covering
the full stack rather than only the software dependencies:

- **npm** — `@yowasp/yosys` 0.68.1207, with the resolved registry URL and the
  lockfile `integrity` value decoded into a CycloneDX `SHA-512` hash. This
  component doubles as the pin for the synthesis and formal toolchain, which
  is why it carries `lca1:role = toolchain:synthesis-and-formal`.
- **Python** — the first-party project is the SBOM's root component, taken
  from `pyproject.toml` (`lca1` 0.1.0, Apache-2.0, zero runtime
  dependencies), plus the declared `setuptools>=68` build requirement.
- **Git submodules** — `third_party/PQClean` and `third_party/picorv32`,
  each recorded with its full 40-character gitlink SHA read from the git
  index, the licenses `NOTICE` actually claims for them, and an explicit
  `lca1:submodule:checked-out = false` plus a coverage gap note (see
  "Gaps").
- **Hardware and IP** — from `fabrication/rev_a_release.json`,
  `fabrication/rev_a_package.json`, and `hardening/lca_butterfly/config.json`:
  the Rev-A release contract as a `device`, the ChipFoundry OpenFrame
  harness as a `framework` pinned to commit `ca732a64…`, the `sky130A` PDK
  and the `sky130_fd_sc_hd` standard cell library as libraries, and the
  `CF_SRAM_8192x32` compiled SRAM macro with its acquisition status.
- **Toolchain** — Node 24.14.0 and npm 11.9.0 from `package.json` engines,
  CPython 3.12.12 from the workflows, the LibreLane `3.0.9` container from
  `.github/workflows/harden.yml`, Icarus Verilog and distribution Yosys as
  unpinned apt packages, `reuse==6.2.0`, `click==8.3.1`, and `YosysHQ/mcy`
  pinned to commit `5a2cad0c…`.
- **Third-party derived files** — the three files `NOTICE` inventories
  (`firmware/fips202_lca.c`, `firmware/fips202.h`, and the CCTV vector JSON),
  each with a SHA-256 of its committed content, which turns `NOTICE` from an
  assertion into something checkable.
- **GitHub Actions** — all six actions used anywhere in `.github/workflows/`,
  each pinned to a full commit SHA with its release tag recorded.

Licensing follows what the repository actually declares, and refuses to
guess. Apache-2.0 for first-party material, CC0-1.0 for the PQClean-derived
FIPS 202 files and the CCTV vectors, ISC for `@yowasp/yosys` and PicoRV32,
and `CC0-1.0 OR MIT OR Apache-2.0` for PQClean as `NOTICE` describes it.
Everything else — PDK, cell library, SRAM macro, OpenFrame, containers,
actions, host tools — carries `NOASSERTION` **with a machine-readable reason**
in the `lca1:license:noassertion-reason` property. A widely known license is
not the same as a declared one, and this SBOM does not launder the
difference. `tests/test_sbom.py` enforces that no component can omit both.

CycloneDX `compositions` state coverage per group: `complete` for the npm
lockfile and the action pins, `incomplete` for submodules, hardware, and
containers, `unknown` for unpinned apt tools.

### Determinism, and two deliberate omissions

`--check` is only a real gate if the generator is a pure function of the
repository. It is: all input is read from committed files (plus the git index
for gitlinks), keys are sorted, nothing is fetched, and nothing is read from
the ambient environment. Two consequences:

- **No `metadata.timestamp`.** CycloneDX makes it optional. A wall-clock
  value would make the document differ on every run and the drift gate
  meaningless. Build time is recorded by the workflow run instead.
- **No embedded repository commit.** A committed file cannot contain the
  hash of the commit that adds it. The commit is bound *externally*, by the
  workflow artifact name (`lca1-sbom-${{ github.sha }}`) and by the
  provenance attestation, which names the commit in its SLSA statement.
  Both omissions are stated inside the document itself as
  `lca1:sbom:timestamp-omitted` and `lca1:sbom:commit-omitted`.

## What this proves — and what it does not

| Artifact | Proves | Does **not** prove |
|---|---|---|
| SBOM | The complete set of dependencies this repository declares, at the pins it declares, with the licenses it declares. | That the pinned things are what they claim to be, that the submodule *contents* are as expected, or that the licenses of undeclared components are as commonly assumed. |
| `verify_reproducible.sh` | Every generated evidence artifact is re-derivable byte for byte from committed sources by the committed tools. | That the sources are correct, that the generators are free of bugs, or that a *compiled* or *hardened* artifact (netlist, GDSII) is reproducible — those flows are not yet covered. |
| SLSA build provenance | These exact digests were produced by this workflow, at this commit, in this repository, on a GitHub-hosted runner, recorded in a public transparency log. | That the artifacts are correct, secure, or fit for any purpose; nor anything at all about artifacts produced outside CI. |
| Combined | An external reviewer can re-derive the evidence, compare digests, and check that CI produced the same digests from the same commit. | Anything about **fabricated silicon**. No SBOM entry, hash, or attestation in this repository describes a physical part. |

This is a software-and-contract provenance story attached to a hardware
program. It says nothing about mask data, wafers, or packaged parts, and
`GOAL.md`'s physical-evidence gates are entirely unaffected by it.

## Independent verification

A third party needs Python 3.12 (3.11+ for `tomllib`) and git. No network
access and no npm install are required.

```bash
git clone https://github.com/0xSoftBoi/LCA-1
cd LCA-1
git checkout <the commit under review>

# 1. Re-derive every generated evidence artifact and diff against the tree.
bash tools/verify_reproducible.sh

# 2. Check the SBOM on its own, printing its SHA-256.
python3 tools/gen_sbom.py --check

# 3. Run the SBOM validation tests (schema shape, licensing, pins).
python3 -m unittest tests.test_sbom -v

# 4. Print the digest to compare against CI and the attestation.
sha256sum docs/sbom.cdx.json
```

To verify the provenance attestation of a CI-produced artifact, download the
`lca1-attested-evidence-<sha>` artifact from a `supply-chain` workflow run
and check it with the GitHub CLI:

```bash
gh attestation verify sbom.cdx.json --repo 0xSoftBoi/LCA-1
```

That command checks the Sigstore signature and transparency-log inclusion,
and prints the workflow, commit, and repository the artifact is bound to.
Compare the commit it reports against the commit you checked out, and the
digest against step 4 above. If they agree, the SBOM you re-derived locally
is the same document CI produced from the same source.

## Gaps

These are open, not hidden. None of them is closed by anything above.

1. **Submodules are not checked out — anywhere.** `third_party/PQClean` and
   `third_party/picorv32` are pinned by gitlink SHA but never populated, in
   this working tree or in CI (no workflow passes `submodules: true`). The
   SBOM records the pin and marks the component `incomplete`; it does **not**
   enumerate the files, transitive dependencies, or per-scheme licenses
   inside either submodule. Closing this means checking them out in a CI job
   and extending the generator to walk their contents.
2. **No signed release tags, and no releases.** There is no tag to attest
   over and no release-artifact signing. Provenance today binds evidence
   artifacts to a commit, which is strictly weaker than a signed, immutable
   release. This should be closed before any external party is asked to
   consume an LCA-1 artifact.
3. **The PDK is not covered bit-for-bit.** `sky130A` and `sky130_fd_sc_hd`
   appear as named components with no version and no hash, because the
   repository vendors no PDK files — the LibreLane container resolves them at
   flow time. Any physical-implementation claim therefore rests on an
   unpinned, unhashed PDK. Closing this means recording the resolved
   `ciel`/volare PDK commit and hashing the fetched tree.
4. **The LibreLane container is pinned by mutable tag, not digest.**
   `.github/workflows/harden.yml` uses `ghcr.io/librelane/librelane:3.0.9`.
   A retag would change the tool without changing this SBOM. The SBOM records
   `lca1:container:digest = NOASSERTION` and flags the gap. Closing it means
   pinning `…@sha256:<digest>` in that workflow — which is outside this
   change's ownership.
5. **Icarus Verilog and distribution Yosys are unpinned.** Both are installed
   with `apt-get install` from the Ubuntu 24.04 archive. The resolved version
   is recorded per run into `reports/`, which makes a past run auditable but
   does not make a future run reproducible.
6. **Hardened outputs are not in the reproducibility loop.** The harness
   covers the vector corpus, the fabrication tables, and the SBOM. It does
   not cover synthesis netlists, formal logs, or LibreLane GDSII — none of
   which is currently known to be bit-reproducible.
7. **Provenance does not run on pull requests.** Fork PRs receive neither an
   OIDC token nor `attestations: write`, so the `provenance` job is gated to
   pushes to `main` and manual dispatch. PRs still run the drift and
   reproducibility gates.
8. **The SBOM is not schema-validated against the official CycloneDX
   schema.** `tests/test_sbom.py` checks structure, licensing, and pins by
   hand, because validating against the published JSON Schema would require a
   network fetch or a vendored copy plus a validator dependency. The
   repository's no-external-dependency rule wins here; the trade is recorded
   rather than papered over.

## How this connects to attestation

The DePIN survey's conclusion is the load-bearing one. Measurement registers,
quotes, and signed receipts are all statements of the form "the artifact with
digest *D* was loaded." That is worth something only if a reviewer can
independently produce an artifact with digest *D* from source they can read.
Without reproducibility, attestation degrades into "trust whoever built it,"
which is exactly the property an open-source hardware program exists to
avoid.

So the dependency runs one way: `verify_reproducible.sh` is the foundation,
`gen_sbom.py` says what went in, and the SLSA attestation is the outermost
layer that binds the reproducible bytes to a commit and a builder. Any future
device-identity or attestation story for LCA-1 silicon — per `GOAL.md`'s
composed-trust table — should extend this chain rather than start a parallel
one. And per the survey's item 7, each claim should carry its provenance
status: everything in this document is `verifier_derived` at best. Nothing
here is `hardware_proven`.
