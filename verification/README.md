# RTL differential regression

`tools/gen_vectors.py` produces
`verification/vectors/butterfly_vectors.txt` from the Python golden model.
The first row contains:

```text
format_version vector_count decimal_seed
```

Each vector row contains ten decimal integers:

```text
case_id modulus_id a b twiddle expected_a expected_b expected_fault hold_cycles expected_latency
```

`expected_latency` counts completed arithmetic cycles after the request
acceptance edge. Canonical operations use 24; rejected inputs start no
arithmetic and use 0. `hold_cycles` exercises response stability while
`rsp_ready` is low.

Regenerate and verify with:

```bash
make vectors
make vectors-check
make rtl-test
```

Corpus changes require review of the generator, seed/count, and resulting
SHA-256 printed by `--check`; editing the generated file alone is invalid.
