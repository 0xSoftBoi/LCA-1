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
| Structural synthesis | elaboration, optimization, generic technology mapping, structural checks and netlist emission | `make synth` | Yosys reports zero structural problems and writes all artifacts |
| Power contract | trace schema and energy integration behavior | `make test-python` | schema/validation and integration tests pass |

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
