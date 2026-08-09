## Outcome

<!-- What falsifiable outcome does this change deliver? -->

## Requirements

<!-- List affected IDs from spec/REQUIREMENTS.md and the controlling Linear issue. -->

- Requirement IDs:
- Linear issue:

## Claim boundary

- [ ] I separated estimates, simulations, generic synthesis, FPGA data, ASIC data, and measurements.
- [ ] I did not add or imply full-algorithm, speedup, PPA, production-security, FIPS, or tapeout claims without matching artifacts.
- [ ] I updated the threat model/interface/non-claims if scope changed.

## Verification

<!-- Paste exact commands and summarize results; link artifacts where applicable. -->

- [ ] `make test-python`
- [ ] `make vectors-check`
- [ ] `make rtl-test`
- [ ] `make formal`
- [ ] `make synth`

## Generated and supply-chain review

- [ ] Generated files were produced by committed tools and pass drift checks.
- [ ] Formal assumptions and proof depth were reviewed for vacuity/scope.
- [ ] Dependency/action changes are pinned and provenance is documented.
- [ ] No key, credential, secret trace, or incompatible third-party material is included.
