# Contributing

## Change contract

Every pull request must identify the requirement IDs it affects, describe any
claim-boundary change, and provide a reproducible verification command. New or
changed behavior without a requirement and negative test is incomplete.

1. Branch from `main` and keep the change focused.
2. Update `spec/REQUIREMENTS.md` and, when scope changes, the threat model and
   interface specification.
3. Regenerate derived files with repository tools; never hand-edit the vector
   corpus or synthesis output.
4. Run `npm ci --ignore-scripts` and `make verify` with Python 3.12, Node
   24.14.0, Icarus Verilog, and the lockfile-pinned Yosys runtime.
5. Record failures honestly. Estimates, simulations, generic synthesis, FPGA
   measurements, and ASIC measurements must remain visibly distinct.
6. Use the pull request template and link the controlling Linear issue.

Do not include keys, credentials, proprietary vectors, export-controlled
material, or third-party code without compatible terms and provenance.

## Review expectations

Changes to RTL, formal assumptions, cryptographic parameters, generated-data
tools, CI, security boundaries, or release inputs require owner review. A green
job is necessary but not sufficient: reviewers must check that the tests still
measure the stated requirement and that assumptions did not make the result
vacuous.

## License and certification of origin

First-party code is licensed under the Apache License 2.0 (`LICENSE`);
third-party and derived material is inventoried in `NOTICE`. Contributions are
accepted under the same terms as the file they modify (inbound = outbound). By
submitting a contribution you certify it under the
[Developer Certificate of Origin 1.1](https://developercertificate.org/);
sign off each commit with `git commit -s`.

New first-party files must carry an `SPDX-License-Identifier` header naming
`Apache-2.0`. Derived files must keep their upstream license, carry the
matching SPDX identifier, and be recorded in `NOTICE` with provenance. The
repository is kept compliant with the [REUSE](https://reuse.software)
specification; run `reuse lint` before submitting.

Participation in this project is governed by `CODE_OF_CONDUCT.md`.
