# SPDX-License-Identifier: Apache-2.0
"""External-oracle tests that break the model-only-oracle circularity.

Until now the Python model was the sole oracle for the RTL, and the NTT zeta
ROM traced only to the pinned PQClean sources. These tests anchor both to
authorities outside the repository:

1. The full forward NTT, built exclusively from the modeled Cooley-Tukey
   butterfly primitive with twiddles derived from the FIPS 203 definition
   (zeta = 17^BitRev7(i) mod 3329), must reproduce the published C2SP/CCTV
   ML-KEM-768 intermediate value NTT(s[0]) from the committed external
   vector file (provenance and hash recorded in the JSON).
2. The inverse NTT, built exclusively from the modeled Gentleman-Sande
   butterfly, must recover the original CCTV polynomial.
3. Every entry of the committed zeta ROM (rtl/lca_ntt_zetas.svh, generated
   from the PQClean pin) must equal the value independently derived from
   the FIPS 203 / FIPS 204 definitions in the PQClean Montgomery domain
   (R = 2^16 for ML-KEM, R = 2^32 for ML-DSA, centered signed form).

A defect in the model's butterfly, the zeta generation, or the PQClean pin
now requires the same defect to exist in NIST's field definition or the
independently maintained CCTV data to go unnoticed.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

from model.reference import Q_MLDSA, Q_MLKEM, ct_butterfly, gs_butterfly, modmul

ROOT = Path(__file__).resolve().parents[1]
CCTV_JSON = ROOT / "verification" / "vectors" / "external" / "cctv_mlkem768_ntt.json"
ZETA_SVH = ROOT / "rtl" / "lca_ntt_zetas.svh"

MLKEM_ROOT = 17
MLDSA_ROOT = 1753
MLKEM_MONT_R = 1 << 16
MLDSA_MONT_R = 1 << 32
MLKEM_INV_128 = pow(128, -1, Q_MLKEM)


def bit_reverse(value: int, bits: int) -> int:
    result = 0
    for _ in range(bits):
        result = (result << 1) | (value & 1)
        value >>= 1
    return result


def centered(value: int, q: int) -> int:
    return value - q if value > q // 2 else value


def fips203_zetas() -> list[int]:
    """zeta_i = 17^BitRev7(i) mod 3329, straight from the FIPS 203 field."""
    return [pow(MLKEM_ROOT, bit_reverse(i, 7), Q_MLKEM) for i in range(128)]


def forward_ntt(poly: list[int]) -> list[int]:
    """FIPS 203 Algorithm 9 using only the modeled CT butterfly."""
    f = list(poly)
    zetas = fips203_zetas()
    i = 1
    length = 128
    while length >= 2:
        for start in range(0, 256, 2 * length):
            zeta = zetas[i]
            i += 1
            for j in range(start, start + length):
                f[j], f[j + length] = ct_butterfly(f[j], f[j + length], zeta, Q_MLKEM)
        length //= 2
    return f


def inverse_ntt(poly: list[int]) -> list[int]:
    """FIPS 203 Algorithm 10 using only the modeled GS butterfly.

    The model's GS butterfly computes (a + b, (a - b) * zeta); FIPS 203
    computes zeta * (b - a), so the twiddle is negated before use.
    """
    f = list(poly)
    zetas = fips203_zetas()
    i = 127
    length = 2
    while length <= 128:
        for start in range(0, 256, 2 * length):
            zeta = (Q_MLKEM - zetas[i]) % Q_MLKEM
            i -= 1
            for j in range(start, start + length):
                f[j], f[j + length] = gs_butterfly(f[j], f[j + length], zeta, Q_MLKEM)
        length *= 2
    return [modmul(value, MLKEM_INV_128, Q_MLKEM) for value in f]


def parse_zeta_rom(function_name: str, sign_bits: int) -> dict[int, int]:
    pattern = re.compile(
        r"8'd(\d+):\s*" + function_name + r"\s*=\s*(-?)" + str(sign_bits) + r"'sd(\d+);"
    )
    entries: dict[int, int] = {}
    for match in pattern.finditer(ZETA_SVH.read_text()):
        index = int(match.group(1))
        value = int(match.group(3))
        entries[index] = -value if match.group(2) == "-" else value
    return entries


class ExternalVectorProvenanceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.doc = json.loads(CCTV_JSON.read_text())

    def test_provenance_fields_present(self) -> None:
        for field in ("source", "source_url", "source_sha256", "license"):
            self.assertIn(field, self.doc)
        self.assertEqual(self.doc["license"], "CC0-1.0")
        self.assertEqual(self.doc["modulus"], Q_MLKEM)

    def test_vector_shape(self) -> None:
        for key in ("input_poly", "expected_ntt"):
            values = self.doc[key]
            self.assertEqual(len(values), 256)
            self.assertTrue(all(0 <= v < Q_MLKEM for v in values))


class CctvNttOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.doc = json.loads(CCTV_JSON.read_text())

    def test_forward_ntt_matches_cctv(self) -> None:
        self.assertEqual(
            forward_ntt(self.doc["input_poly"]), self.doc["expected_ntt"]
        )

    def test_inverse_ntt_recovers_cctv_input(self) -> None:
        self.assertEqual(
            inverse_ntt(self.doc["expected_ntt"]), self.doc["input_poly"]
        )


class ZetaRomFipsDerivationTests(unittest.TestCase):
    def test_mlkem_rom_matches_fips203_derivation(self) -> None:
        rom = parse_zeta_rom("mlkem_zeta", 16)
        self.assertEqual(len(rom), 128)
        for index in range(128):
            plain = pow(MLKEM_ROOT, bit_reverse(index, 7), Q_MLKEM)
            expected = centered(plain * MLKEM_MONT_R % Q_MLKEM, Q_MLKEM)
            self.assertEqual(
                rom[index], expected, f"mlkem zeta ROM mismatch at index {index}"
            )

    def test_mldsa_rom_matches_fips204_derivation(self) -> None:
        rom = parse_zeta_rom("mldsa_zeta", 32)
        self.assertEqual(len(rom), 256)
        self.assertEqual(rom[0], 0)
        for index in range(1, 256):
            plain = pow(MLDSA_ROOT, bit_reverse(index, 8), Q_MLDSA)
            expected = centered(plain * MLDSA_MONT_R % Q_MLDSA, Q_MLDSA)
            self.assertEqual(
                rom[index], expected, f"mldsa zeta ROM mismatch at index {index}"
            )


if __name__ == "__main__":
    unittest.main()
