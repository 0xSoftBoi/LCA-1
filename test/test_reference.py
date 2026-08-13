from __future__ import annotations

import random
import unittest

from model.reference import (
    OP_CT,
    OP_GS,
    OP_MUL,
    Q_MLDSA,
    Q_MLKEM,
    ct_butterfly,
    execute,
    gs_butterfly,
    modmul,
)


class TestLCAReference(unittest.TestCase):
    def test_fips_moduli(self) -> None:
        self.assertEqual(Q_MLKEM, 3329)
        self.assertEqual(Q_MLDSA, 8380417)

    def test_modmul_edges(self) -> None:
        for q in (Q_MLKEM, Q_MLDSA):
            vectors = (
                (0, 0),
                (0, q - 1),
                (1, q - 1),
                (q - 1, q - 1),
                (2, q - 2),
                (q // 2, q // 3),
            )
            for a, b in vectors:
                with self.subTest(q=q, a=a, b=b):
                    self.assertEqual(modmul(a, b, q), (a * b) % q)

    def test_modmul_deterministic_random_vectors(self) -> None:
        rng = random.Random(0x4C434131)  # ASCII-ish "LCA1"
        for q in (Q_MLKEM, Q_MLDSA):
            for _ in range(1000):
                a = rng.randrange(q)
                b = rng.randrange(q)
                self.assertEqual(modmul(a, b, q), (a * b) % q)

    def test_ct_butterfly(self) -> None:
        rng = random.Random(0x4354)
        for q in (Q_MLKEM, Q_MLDSA):
            for _ in range(500):
                a, b, zeta = (rng.randrange(q) for _ in range(3))
                out0, out1 = ct_butterfly(a, b, zeta, q)
                t = (b * zeta) % q
                self.assertEqual(out0, (a + t) % q)
                self.assertEqual(out1, (a - t) % q)

    def test_gs_butterfly(self) -> None:
        rng = random.Random(0x4753)
        for q in (Q_MLKEM, Q_MLDSA):
            for _ in range(500):
                a, b, zeta = (rng.randrange(q) for _ in range(3))
                out0, out1 = gs_butterfly(a, b, zeta, q)
                self.assertEqual(out0, (a + b) % q)
                self.assertEqual(out1, (((a - b) % q) * zeta) % q)

    def test_command_dispatch(self) -> None:
        for mode_kem, q in ((True, Q_MLKEM), (False, Q_MLDSA)):
            a, b, zeta = q - 2, q - 3, q - 5
            self.assertEqual(execute(OP_MUL, mode_kem, a, b), ((a * b) % q, 0))
            self.assertEqual(execute(OP_CT, mode_kem, a, b, zeta), ct_butterfly(a, b, zeta, q))
            self.assertEqual(execute(OP_GS, mode_kem, a, b, zeta), gs_butterfly(a, b, zeta, q))

    def test_rejects_noncanonical_values(self) -> None:
        for q in (Q_MLKEM, Q_MLDSA):
            for value in (-1, q, q + 1):
                with self.subTest(q=q, value=value):
                    with self.assertRaises(ValueError):
                        modmul(value, 1, q)
                    with self.assertRaises(ValueError):
                        modmul(1, value, q)

    def test_rejects_unknown_opcode(self) -> None:
        with self.assertRaises(ValueError):
            execute(3, False, 1, 1)


if __name__ == "__main__":
    unittest.main()
