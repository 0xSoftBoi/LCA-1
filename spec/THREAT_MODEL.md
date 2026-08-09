# Threat model

## Assets

- ML-KEM decapsulation keys and shared secrets;
- ML-DSA signing keys and sensitive signing intermediates;
- plaintext lattice-key payloads and CEKs;
- correctness of verification results and completion status;
- availability of the bridge verifier without fail-open behavior.

## Adversaries

| Adversary | Capability |
|---|---|
| Malicious host process | malformed descriptors, aliasing buffers, resets, replays, timing observation |
| Malicious bridge input | invalid keys, ciphertexts, signatures, encodings, or extreme lengths |
| Bus observer | observes host/accelerator traffic and timing |
| Physical attacker | power/EM observation, clock/voltage glitch, invasive probing |
| Supply-chain attacker | modified RTL, build tools, FPGA bitstream, firmware, or dependencies |

## Required controls

- fixed-latency arithmetic where practical and no secret-dependent early exit;
- strict public-key, ciphertext, signature, and descriptor length checks;
- fail-closed completion: errors never become a successful verification;
- explicit zeroize command plus zeroization on reset, timeout, and fatal fault;
- counters that expose performance without exposing secret-dependent values;
- domain separation remains in host/reference algorithm code;
- reproducible tool versions, source hashes, and generated reports;
- differential tests against a pinned FIPS-conformant software backend;
- fault-injection tests before any bridge money path uses the device.

## Claim boundary

This repository can demonstrate functional equivalence of individual RTL
blocks. It does not yet demonstrate:

- a complete constant-time ML-KEM or ML-DSA implementation;
- resistance to power, EM, or fault-injection attacks;
- secure key storage;
- FIPS 140-3 module validation or CMVP certification;
- safe production use in a money-moving bridge.

Those require a defined cryptographic module boundary, physical device,
laboratory evidence, validated entropy/key management, and independent review.

## ETP-specific fail-closed rule

If LCA-1 is absent, times out, resets, or returns an internal fault, ETP must
fall back to a known-good software implementation or reject the operation. It
must never reinterpret an accelerator error as a valid signature, successful
decapsulation, or finalized bridge message.
