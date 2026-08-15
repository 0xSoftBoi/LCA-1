# Verification plan

## Strategy

LCA-1 uses layered evidence. No single layer is treated as proof of the whole
cryptographic system.

| Layer | Scope | Command | Pass condition |
|---|---|---|---|
| Golden model | modular add/subtract/multiply and butterfly over both production moduli | `make test-python` | 4,000 multiplies and 4,000 butterflies match Python integer arithmetic; validation tests pass |
| Generated corpus | model-to-RTL test stimulus integrity | `make vectors-check` | 280 committed cases exactly match format 1, seed `0x1ca1e001`, and the generator output |
| RTL simulation | full-width outputs, exact latency, malformed inputs, backpressure, reset/recovery | `make rtl-test` | all 280 corpus cases and the reset case pass with no timeout |
| Formal arithmetic | shift/add algorithm for every canonical input pair at four bits and `q=13` | `make formal` | bounded SAT proof has no counterexample |
| Formal protocol | full 24-bit fixed response point and held response; full-width malformed-input rejection | `make formal` | both bounded SAT proofs have no counterexample |
| Formal induction | unbounded handshake-safety, counter-bound, and response/fault-stability invariants of `lca_modmul` and `lca_butterfly` with all inputs unconstrained | `make formal` | both temporal-induction proofs close (base case plus induction step) |
| External oracle | forward/inverse NTT built solely from the modeled butterfly against committed C2SP/CCTV ML-KEM-768 intermediate values; zeta ROM against independent FIPS 203/204 derivations | `make test-python` | CCTV transform and round-trip match; all 384 ROM entries match the FIPS-derived Montgomery-domain values |
| Structural synthesis | elaboration, optimization, generic technology mapping, structural checks and netlist emission | `make synth` | Yosys reports zero structural problems and writes all artifacts |
| Power contract | trace schema and energy integration behavior | `make test-python` | schema/validation and integration tests pass |
| Mutation coverage (signal) | kill ratio of the generated corpus over injected netlist mutations of the arithmetic slice | nightly `mutation` workflow / `verification/mutation/README.md` | reported ratio is a monitored lower bound, not a gate; surviving non-equivalent mutants become corpus defects |

## Corpus design

The corpus contains, for each supported modulus, eight boundary/structured
cases and 128 pseudorandom cases. It also contains eight negative cases: every
operand equal to its modulus and both unsupported modulus IDs. Response
backpressure is held for zero through three cycles across the valid corpus and
one through three cycles across malformed cases.

The first corpus row is:

```text
format_version vector_count decimal_seed
```

Every remaining row follows `verification/README.md`. The generator is
dependency-free and derives expected values from `model/modarith.py`.

## Formal limits

- The arithmetic proof is exhaustive only for the parameterized four-bit
  instance at `q=13`; full-width differential simulation covers the production
  moduli.
- The 24-bit protocol proof uses a representative canonical transaction. It
  proves the control trajectory and held result for that transaction, not all
  arithmetic values.
- The malformed-input proof covers the implemented wrapper's canonical-range
  rejection path.
- The temporal-induction proofs cover protocol invariants (mutual exclusion,
  readiness definition, counter bound, response/fault stability) for all
  inputs and all time, but not arithmetic values; the invariants live in the
  RTL under `ifdef FORMAL` and are invisible to synthesis and simulation.
- The external-oracle layer anchors the butterfly schedule, twiddle
  derivation, and zeta ROM to FIPS 203/204 definitions and independently
  maintained CCTV data; it does not cover Keccak, sampling, or any complete
  scheme operation.
- None of the proofs cover a future NTT, Keccak, SRAM, entropy, DMA, driver, or
  complete ML-KEM/ML-DSA operation.
- Digital evidence does not establish physical side-channel or fault
  resistance, clock/reset-domain correctness outside this synchronous slice,
  FPGA/ASIC timing, or tool correctness.

## CI evidence

CI records Python, Node, npm, Icarus, and Yosys versions. The hardware job
uploads `reports/` for 30 days, including formal and synthesis logs, generic
statistics, and JSON/Verilog netlists. Generic cell counts are useful for
regression only and shall not be published as target area or PPA.

Any counterexample, corpus drift, simulator mismatch, timeout, structural
check failure, or missing generated artifact fails the relevant job.
