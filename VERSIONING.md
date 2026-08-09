# Version and compatibility policy

The repository uses semantic versions for evidence releases while it remains
pre-1.0:

- **patch**: tests, documentation, tooling, or fixes that do not intentionally
  change the v0 request/response contract;
- **minor**: additive behavior, a new verified block, or an intentional
  interface/evidence-schema change;
- **major / 1.0**: considered only after the complete algorithm, host
  integration, physical security, and production-qualification gates pass.

RTL interfaces, descriptor ABIs, vector formats, power schemas, and generated
artifacts carry their own explicit format/version fields where applicable. A
tag identifies source; it does not by itself certify security or hardware
fitness. Release notes must list requirement IDs, toolchain lock changes,
artifacts, known limitations, and claim-boundary changes.
