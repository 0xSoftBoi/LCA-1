// SPDX-License-Identifier: Apache-2.0
#ifndef LCA_MMIO_H
#define LCA_MMIO_H

#include <stddef.h>
#include <stdint.h>

#define LCA_MAILBOX_BASE 0x20000000u
#define LCA_KECCAK_BASE  0x20001000u
#define LCA_NTT_BASE     0x20002000u
#define LCA_ARITH_BASE   0x20003000u

#define LCA_MLDSA_PK  ((const uint8_t *)0x10060000u)
#define LCA_MLDSA_SIG ((const uint8_t *)0x10060800u)
#define LCA_MESSAGE   ((const uint8_t *)0x10061600u)
#define LCA_CONTEXT   ((const uint8_t *)0x10071600u)
#define LCA_MLKEM_DK  ((const uint8_t *)0x10071700u)
#define LCA_MLKEM_CT  ((const uint8_t *)0x10072080u)

#define LCA_CMD_MLDSA65_VERIFY  0x01u
#define LCA_CMD_MLKEM768_DECAPS 0x02u
#define LCA_CMD_SELF_TEST       0x03u

#define LCA_RESULT_OK                0x00u
#define LCA_RESULT_INVALID_SIGNATURE 0x01u
#define LCA_RESULT_BAD_COMMAND       0x80u
#define LCA_RESULT_INTERNAL          0x83u
#define LCA_RESULT_SELF_TEST         0x84u

static inline uint32_t lca_mmio_read(uintptr_t address) {
    return *(volatile const uint32_t *)address;
}

static inline void lca_mmio_write(uintptr_t address, uint32_t value) {
    *(volatile uint32_t *)address = value;
}

#endif
