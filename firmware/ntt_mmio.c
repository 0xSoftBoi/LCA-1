// SPDX-License-Identifier: Apache-2.0
// PQClean-compatible NTT entry points backed by the shared RTL accelerator.

#include <stdint.h>

#include "lca_mmio.h"

#define NTT_CTRL  (*(volatile uint32_t *)(LCA_NTT_BASE + 0x000u))
#define NTT_COEFF ((volatile uint32_t *)(LCA_NTT_BASE + 0x100u))

// ML-KEM still uses its NTT-domain two-coefficient base multiplication in
// firmware. Keep the standardized Montgomery twiddles visible under the exact
// PQClean ABI while offloading full forward/inverse transforms below.
const int16_t PQCLEAN_MLKEM768_CLEAN_zetas[128] = {
    -1044, -758, -359, -1517, 1493, 1422, 287, 202,
    -171, 622, 1577, 182, 962, -1202, -1474, 1468,
    573, -1325, 264, 383, -829, 1458, -1602, -130,
    -681, 1017, 732, 608, -1542, 411, -205, -1571,
    1223, 652, -552, 1015, -1293, 1491, -282, -1544,
    516, -8, -320, -666, -1618, -1162, 126, 1469,
    -853, -90, -271, 830, 107, -1421, -247, -951,
    -398, 961, -1508, -725, 448, -1065, 677, -1275,
    -1103, 430, 555, 843, -1251, 871, 1550, 105,
    422, 587, 177, -235, -291, -460, 1574, 1653,
    -246, 778, 1159, -147, -777, 1483, -602, 1119,
    -1590, 644, -872, 349, 418, 329, -156, -75,
    817, 1097, 603, 610, 1322, -1285, -1465, 384,
    -1215, -136, 1218, -1335, -874, 220, -1187, -1659,
    -1185, -1530, -1278, 794, -1510, -854, -870, 478,
    -108, -308, 996, 991, 958, -1460, 1522, 1628,
};

extern int16_t PQCLEAN_MLKEM768_CLEAN_montgomery_reduce(int32_t value);

static int16_t mlkem_fqmul(int16_t left, int16_t right) {
    return PQCLEAN_MLKEM768_CLEAN_montgomery_reduce((int32_t)left * right);
}

void PQCLEAN_MLKEM768_CLEAN_basemul(int16_t result[2], const int16_t left[2],
                                    const int16_t right[2], int16_t zeta) {
    result[0] = mlkem_fqmul(left[1], right[1]);
    result[0] = mlkem_fqmul(result[0], zeta);
    result[0] += mlkem_fqmul(left[0], right[0]);
    result[1] = mlkem_fqmul(left[0], right[1]);
    result[1] += mlkem_fqmul(left[1], right[0]);
}

enum {
    NTT_MLDSA_FORWARD = 0,
    NTT_MLDSA_INVERSE = 1,
    NTT_MLKEM_FORWARD = 2,
    NTT_MLKEM_INVERSE = 3,
};

static void run_mldsa(int32_t values[256], unsigned int command) {
    unsigned int i;
    for (i = 0; i < 256u; ++i) {
        NTT_COEFF[i] = (uint32_t)values[i];
    }
    NTT_CTRL = 1u | (command << 1);
    while ((NTT_CTRL & 1u) != 0u) {
    }
    for (i = 0; i < 256u; ++i) {
        values[i] = (int32_t)NTT_COEFF[i];
    }
}

static void run_mlkem(int16_t values[256], unsigned int command) {
    unsigned int i;
    for (i = 0; i < 256u; ++i) {
        NTT_COEFF[i] = (uint32_t)(int32_t)values[i];
    }
    NTT_CTRL = 1u | (command << 1);
    while ((NTT_CTRL & 1u) != 0u) {
    }
    for (i = 0; i < 256u; ++i) {
        values[i] = (int16_t)NTT_COEFF[i];
    }
}

void PQCLEAN_MLDSA65_CLEAN_ntt(int32_t values[256]) {
    run_mldsa(values, NTT_MLDSA_FORWARD);
}

void PQCLEAN_MLDSA65_CLEAN_invntt_tomont(int32_t values[256]) {
    run_mldsa(values, NTT_MLDSA_INVERSE);
}

void PQCLEAN_MLKEM768_CLEAN_ntt(int16_t values[256]) {
    run_mlkem(values, NTT_MLKEM_FORWARD);
}

void PQCLEAN_MLKEM768_CLEAN_invntt(int16_t values[256]) {
    run_mlkem(values, NTT_MLKEM_INVERSE);
}
