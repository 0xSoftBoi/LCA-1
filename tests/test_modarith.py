from __future__ import annotations

import random
import unittest

from model.modarith import DSA_Q, KEM_Q, WORD_BITS, add_mod, butterfly, mul_mod_shift_add, sub_mod


class ModularArithmeticTests(unittest.TestCase):
    def test_edges(self) -> None:
        for modulus in (KEM_Q, DSA_Q):
            with self.subTest(modulus=modulus):
                self.assertEqual(add_mod(modulus - 1, 1, modulus), 0)
                self.assertEqual(sub_mod(0, 1, modulus), modulus - 1)
                result = mul_mod_shift_add(modulus - 1, modulus - 1, modulus)
                self.assertEqual(result.value, 1)
                self.assertEqual(result.cycles, WORD_BITS)

    def test_random_multiplication_matches_python(self) -> None:
        rng = random.Random(0x1CA1)
        for modulus in (KEM_Q, DSA_Q):
            for _ in range(2_000):
                a = rng.randrange(modulus)
                b = rng.randrange(modulus)
                result = mul_mod_shift_add(a, b, modulus)
                self.assertEqual(result.value, (a * b) % modulus)
                self.assertEqual(result.cycles, WORD_BITS)

    def test_random_butterflies(self) -> None:
        rng = random.Random(0xB0773)
        for modulus in (KEM_Q, DSA_Q):
            for _ in range(2_000):
                a = rng.randrange(modulus)
                b = rng.randrange(modulus)
                twiddle = rng.randrange(modulus)
                result = butterfly(a, b, twiddle, modulus)
                product = (b * twiddle) % modulus
                self.assertEqual(result.out_a, (a + product) % modulus)
                self.assertEqual(result.out_b, (a - product) % modulus)
                self.assertEqual(result.cycles, WORD_BITS)

    def test_rejects_noncanonical_input(self) -> None:
        with self.assertRaises(ValueError):
            mul_mod_shift_add(KEM_Q, 1, KEM_Q)
        with self.assertRaises(ValueError):
            butterfly(1, -1, 2, DSA_Q)
        with self.assertRaises(ValueError):
            mul_mod_shift_add(1, 1, 17)


if __name__ == "__main__":
    unittest.main()
