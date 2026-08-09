# Formal checks

`formal/prove.ys` runs three bounded proofs with Yosys's built-in SAT engine:

1. exhaustive arithmetic equivalence for every canonical input pair at a
   reduced four-bit width and prime modulus `q=13`;
2. the full 24-bit multiplier's exact control latency and response stability
   under backpressure for a representative canonical transaction; and
3. full-width fail-closed rejection and response stability for a
   non-canonical butterfly request.

Run them with:

```bash
make formal
```

These proofs strengthen the simulation evidence, but they do not prove the
complete ML-KEM or ML-DSA algorithms, physical side-channel resistance, clock
or reset-domain crossings, a future DMA subsystem, or tool correctness.
