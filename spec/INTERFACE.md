# Interface specification

## v0 RTL slice

The first slice is a request/response butterfly interface.

| Signal | Direction | Meaning |
|---|---|---|
| `clk`, `rst_n` | input | synchronous clock, active-low reset |
| `req_valid`, `req_ready` | handshake | one request is accepted when both are high |
| `req_modulus_id` | input | `0`: ML-KEM `q=3329`; `1`: ML-DSA `q=8380417` |
| `req_a`, `req_b`, `req_twiddle` | input | canonical residues in `[0,q)` |
| `rsp_valid`, `rsp_ready` | handshake | response remains stable until accepted |
| `rsp_a`, `rsp_b` | output | modular butterfly outputs |
| `fault` | output | invalid modulus or non-canonical operand |

A valid request returns in 24 cycles. Invalid inputs return `fault` without
starting arithmetic. There is one in-flight request.

## Future command descriptor

The host-facing v1 descriptor is intentionally narrow:

```text
opcode          u16   KEM_ENCAPS, KEM_DECAPS, DSA_SIGN, DSA_VERIFY, SELF_TEST, ZEROIZE
parameter_set   u16   ML_KEM_768 or ML_DSA_65
flags           u32   deterministic-test only, telemetry, interrupt
input_addr      u64   DMA address
input_len       u32   exact standard-defined length
output_addr     u64   DMA address
output_capacity u32
context_addr    u64   optional public context
context_len     u16   <=255 for ML-DSA
request_id      u64   caller-generated replay-safe identifier
```

Completion contains status, request ID, bytes written, total cycles, stall
cycles, active cycles, and fault code. Secret data never appears in telemetry.

## Errors

At minimum: invalid opcode, unsupported parameter set, invalid length,
non-canonical coefficient, DMA range/alignment fault, timeout, entropy failure,
self-test failure, zeroization failure, and internal invariant failure.

All errors are fail-closed and sticky until the completion is consumed.
