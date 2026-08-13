// SPDX-License-Identifier: Apache-2.0
// End-to-end Level-3 algorithm regression against the pinned PQClean sources.

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../third_party/PQClean/crypto_kem/ml-kem-768/clean/api.h"
#include "../third_party/PQClean/crypto_sign/ml-dsa-65/clean/api.h"

static uint64_t random_state = UINT64_C(0x6c6361315f6c7470);

int PQCLEAN_randombytes(uint8_t *output, size_t count) {
    size_t i;

    for (i = 0; i < count; ++i) {
        // Deterministic xorshift64* is intentional: this is a reproducible
        // regression source, never a production entropy implementation.
        random_state ^= random_state >> 12;
        random_state ^= random_state << 25;
        random_state ^= random_state >> 27;
        output[i] = (uint8_t)((random_state * UINT64_C(0x2545f4914f6cdd1d)) >> 56);
    }
    return 0;
}

static int require(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        return 0;
    }
    return 1;
}

static int test_mlkem768(void) {
    uint8_t public_key[PQCLEAN_MLKEM768_CLEAN_CRYPTO_PUBLICKEYBYTES];
    uint8_t decapsulation_key[PQCLEAN_MLKEM768_CLEAN_CRYPTO_SECRETKEYBYTES];
    uint8_t ciphertext[PQCLEAN_MLKEM768_CLEAN_CRYPTO_CIPHERTEXTBYTES];
    uint8_t encapsulated_secret[PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES];
    uint8_t decapsulated_secret[PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES];
    uint8_t rejected_secret[PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES];

    if (!require(PQCLEAN_MLKEM768_CLEAN_crypto_kem_keypair(
                     public_key, decapsulation_key) == 0,
                 "ML-KEM-768 key generation")) {
        return 0;
    }
    if (!require(PQCLEAN_MLKEM768_CLEAN_crypto_kem_enc(
                     ciphertext, encapsulated_secret, public_key) == 0,
                 "ML-KEM-768 encapsulation")) {
        return 0;
    }
    if (!require(PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec(
                     decapsulated_secret, ciphertext, decapsulation_key) == 0,
                 "ML-KEM-768 decapsulation")) {
        return 0;
    }
    if (!require(memcmp(encapsulated_secret, decapsulated_secret,
                        sizeof(encapsulated_secret)) == 0,
                 "ML-KEM-768 shared-secret agreement")) {
        return 0;
    }

    // FIPS 203 decapsulation uses implicit rejection: a malformed ciphertext
    // still returns success but produces a pseudorandom rejection secret.
    ciphertext[137] ^= 0x40u;
    if (!require(PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec(
                     rejected_secret, ciphertext, decapsulation_key) == 0,
                 "ML-KEM-768 implicit-rejection execution")) {
        return 0;
    }
    if (!require(memcmp(encapsulated_secret, rejected_secret,
                        sizeof(encapsulated_secret)) != 0,
                 "ML-KEM-768 malformed ciphertext rejection secret")) {
        return 0;
    }
    return 1;
}

static int test_mldsa65(void) {
    static const uint8_t context[] = "suwappu:lattice-bridge:v1";
    static const uint8_t wrong_context[] = "suwappu:lattice-bridge:v2";
    uint8_t message[] = {
        0x4c, 0x54, 0x50, 0x01, 0x00, 0x00, 0x00, 0x2a,
        0x73, 0x75, 0x77, 0x61, 0x70, 0x70, 0x75, 0x2d,
        0x6c, 0x61, 0x74, 0x74, 0x69, 0x63, 0x65, 0x2d,
        0x62, 0x72, 0x69, 0x64, 0x67, 0x65, 0x00,
    };
    uint8_t public_key[PQCLEAN_MLDSA65_CLEAN_CRYPTO_PUBLICKEYBYTES];
    uint8_t secret_key[PQCLEAN_MLDSA65_CLEAN_CRYPTO_SECRETKEYBYTES];
    uint8_t signature[PQCLEAN_MLDSA65_CLEAN_CRYPTO_BYTES];
    size_t signature_length = 0;

    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_keypair(
                     public_key, secret_key) == 0,
                 "ML-DSA-65 key generation")) {
        return 0;
    }
    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_signature_ctx(
                     signature, &signature_length,
                     message, sizeof(message),
                     context, sizeof(context) - 1u,
                     secret_key) == 0,
                 "ML-DSA-65 signing with context")) {
        return 0;
    }
    if (!require(signature_length == PQCLEAN_MLDSA65_CLEAN_CRYPTO_BYTES,
                 "ML-DSA-65 exact signature length")) {
        return 0;
    }
    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx(
                     signature, signature_length,
                     message, sizeof(message),
                     context, sizeof(context) - 1u,
                     public_key) == 0,
                 "ML-DSA-65 valid signature verification")) {
        return 0;
    }

    message[9] ^= 0x01u;
    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx(
                     signature, signature_length,
                     message, sizeof(message),
                     context, sizeof(context) - 1u,
                     public_key) != 0,
                 "ML-DSA-65 tampered message rejection")) {
        return 0;
    }
    message[9] ^= 0x01u;

    signature[711] ^= 0x80u;
    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx(
                     signature, signature_length,
                     message, sizeof(message),
                     context, sizeof(context) - 1u,
                     public_key) != 0,
                 "ML-DSA-65 tampered signature rejection")) {
        return 0;
    }
    signature[711] ^= 0x80u;

    if (!require(PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx(
                     signature, signature_length,
                     message, sizeof(message),
                     wrong_context, sizeof(wrong_context) - 1u,
                     public_key) != 0,
                 "ML-DSA-65 wrong-context rejection")) {
        return 0;
    }
    return 1;
}

int main(void) {
    if (!test_mlkem768() || !test_mldsa65()) {
        return 1;
    }
    puts("PASS: ML-KEM-768 decapsulation and ML-DSA-65 verification end to end");
    return 0;
}
