# Workload specification

## Authoritative source

The reference workload is
[`0xSoftBoi/Entanglement-Transfer-Protocol`](https://github.com/0xSoftBoi/Entanglement-Transfer-Protocol)
at commit `36b3c9725bc24bad396699767cc4efc85e7ee33c`.

Relevant paths:

- `src/ltp/primitives.py` — ML-KEM-768 and ML-DSA-65 backend boundary;
- `src/ltp/keypair.py` — ML-KEM sealed box;
- `src/ltp/lattice.py` — sealed LatticeKey payload;
- `src/ltp/protocol.py` — COMMIT/LATTICE/MATERIALIZE orchestration;
- `src/ltp/bridge/relayer.py` — encapsulation and optional relay signature;
- `src/ltp/bridge/materializer.py` — decapsulation and signature verification;
- `docs/bridge-mvp-scope.md` — bridge acceptance flow.

The Suwappu integration policy is currently documented on the unmerged
`agent/pq-settlement-profile` branch in `0xSoftBoi/suwappubot`. It keeps
post-quantum settlement disabled until the bridge, verifier, execution client,
conformance vectors, provider, executor, and testnet end-to-end gates pass.
LCA-1 does not weaken any of those gates.

## One authenticated bridge operation

The current ETP bridge path has the following high-level cryptographic work:

| Phase | Primitive | Count | Notes |
|---|---:|---:|---|
| COMMIT | ML-DSA-65 sign | 1 | commitment record |
| LATTICE | ML-KEM-768 encapsulate | 1 | seal CEK and commitment reference to destination verifier |
| RELAY | ML-DSA-65 sign | 0 or 1 | authenticated relay envelope |
| MATERIALIZE | ML-KEM-768 decapsulate | 1 | recover the sealed-key secret |
| MATERIALIZE | ML-DSA-65 verify | 1 | commitment signature |
| MATERIALIZE | ML-DSA-65 verify | 0 or 1 | authenticated relay envelope |

The benchmark defaults to the authenticated path: one encapsulation, one
decapsulation, two signatures, and two verifications.

This table is not an NTT operation count. SHAKE, sampling, packing, AEAD,
Merkle hashing, erasure coding, memory movement, and host validation are still
part of the end-to-end result.

## Pinned NIST parameters

| Primitive | Parameters used by ETP | Arithmetic relevant to LCA-1 |
|---|---|---|
| ML-KEM-768 | `n=256`, `q=3329`, `k=3`, `eta1=2`, `eta2=2`, `du=10`, `dv=4` | 12-bit coefficients; incomplete NTT over 128 quadratic factors |
| ML-DSA-65 | `n=256`, `q=8380417`, `(k,l)=(6,5)`, `eta=4`, `tau=49`, `omega=55` | 23-bit coefficients; 256-point NTT |

Primary standards:

- [NIST FIPS 203](https://doi.org/10.6028/NIST.FIPS.203)
- [NIST FIPS 204](https://doi.org/10.6028/NIST.FIPS.204)

FIPS 203 and FIPS 204 both have published errata notices. Every conformance
run must record the standard revision and errata date it used.

## Benchmark profiles

1. **Minimal protocol:** commitment signature + ML-KEM seal/unseal + commitment verification.
2. **Authenticated relay:** minimal protocol + relay-envelope signature and verification.
3. **Batch:** 1, 8, 64, and 256 independent transfers.
4. **Adversarial:** malformed key/signature lengths, corrupted ciphertext, invalid signature,
   absent accelerator, timeout, reset during operation, and replayed completion.

## Real-backend gate

ETP can fall back to PoC cryptographic simulations when optional dependencies
are absent or do not match the selected parameter set. LCA-1 benchmark results
are invalid unless the harness proves all of the following before timing:

- `real_backend_active()` is true;
- active parameters are ML-KEM-768 and ML-DSA-65;
- key, ciphertext, and signature sizes match FIPS 203/204;
- known-answer and negative tests pass;
- the pinned ETP commit and dependency versions are recorded.

A PoC fallback is useful for API tests, never for LCA performance evidence.

## Primary acceptance metrics

- completed authenticated bridge operations per second;
- p50, p95, and p99 end-to-end latency;
- joules per completed bridge operation;
- peak and sustained board power;
- bytes transferred across the host/accelerator boundary;
- accelerator and local-memory utilization;
- CPU-only and GPU baselines on named hardware;
- malformed-input and reset recovery behavior.

Raw NTT throughput is a diagnostic metric, not the headline result.
