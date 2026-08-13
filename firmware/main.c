// SPDX-License-Identifier: Apache-2.0
// Immutable command firmware for the LCA-1 Level-3 bridge accelerator.

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "fips202.h"
#include "lca_mmio.h"
#include "../third_party/PQClean/crypto_kem/ml-kem-768/clean/api.h"
#include "../third_party/PQClean/crypto_sign/ml-dsa-65/clean/api.h"

static void secure_clear(void *pointer, size_t count) {
    volatile uint8_t *bytes = (volatile uint8_t *)pointer;
    while (count-- != 0u) {
        *bytes++ = 0u;
    }
}

static void complete(uint8_t result_code, uint16_t result_len) {
    lca_mmio_write(LCA_MAILBOX_BASE + 0x08u, result_len);
    lca_mmio_write(LCA_MAILBOX_BASE + 0x04u, result_code);
}

static int self_test(void) {
    static const uint8_t shake256_empty[32] = {
        0x46, 0xb9, 0xdd, 0x2b, 0x0b, 0xa8, 0x8d, 0x13,
        0x23, 0x3b, 0x3f, 0xeb, 0x74, 0x3e, 0xeb, 0x24,
        0x3f, 0xcd, 0x52, 0xea, 0x62, 0xb8, 0x1b, 0x82,
        0xb5, 0x0c, 0x27, 0x64, 0x6e, 0xd5, 0x76, 0x2f,
    };
    uint8_t output[32];
    shake256(output, sizeof(output), NULL, 0);
    if (memcmp(output, shake256_empty, sizeof(output)) != 0) {
        secure_clear(output, sizeof(output));
        return -1;
    }
    secure_clear(output, sizeof(output));
    return 0;
}

int main(void) {
    for (;;) {
        uint32_t status;
        uint8_t command;
        do {
            status = lca_mmio_read(LCA_MAILBOX_BASE + 0x00u);
        } while ((status & 0x2u) == 0u);

        command = (uint8_t)lca_mmio_read(LCA_MAILBOX_BASE + 0x04u);
        lca_mmio_write(LCA_MAILBOX_BASE + 0x00u, 1u); // claim atomically

        if (command == LCA_CMD_MLDSA65_VERIFY) {
            size_t message_len = lca_mmio_read(LCA_MAILBOX_BASE + 0x08u);
            size_t context_len = lca_mmio_read(LCA_MAILBOX_BASE + 0x0cu);
            int result = PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx(
                LCA_MLDSA_SIG,
                PQCLEAN_MLDSA65_CLEAN_CRYPTO_BYTES,
                LCA_MESSAGE,
                message_len,
                LCA_CONTEXT,
                context_len,
                LCA_MLDSA_PK
            );
            complete(result == 0 ? LCA_RESULT_OK : LCA_RESULT_INVALID_SIGNATURE, 0u);
        } else if (command == LCA_CMD_MLKEM768_DECAPS) {
            uint8_t shared_secret[PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES];
            unsigned int i;
            int result = PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec(
                shared_secret, LCA_MLKEM_CT, LCA_MLKEM_DK
            );
            if (result != 0) {
                secure_clear(shared_secret, sizeof(shared_secret));
                complete(LCA_RESULT_INTERNAL, 0u);
                continue;
            }
            for (i = 0; i < 8u; ++i) {
                uint32_t word = (uint32_t)shared_secret[4u * i] |
                    ((uint32_t)shared_secret[4u * i + 1u] << 8) |
                    ((uint32_t)shared_secret[4u * i + 2u] << 16) |
                    ((uint32_t)shared_secret[4u * i + 3u] << 24);
                lca_mmio_write(LCA_MAILBOX_BASE + 0x40u + 4u * i, word);
            }
            secure_clear(shared_secret, sizeof(shared_secret));
            complete(LCA_RESULT_OK, PQCLEAN_MLKEM768_CLEAN_CRYPTO_BYTES);
        } else if (command == LCA_CMD_SELF_TEST) {
            complete(self_test() == 0 ? LCA_RESULT_OK : LCA_RESULT_SELF_TEST, 0u);
        } else {
            complete(LCA_RESULT_BAD_COMMAND, 0u);
        }
    }
}
