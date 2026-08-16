# SPDX-License-Identifier: Apache-2.0
"""Evidence for ``model/fastmod.py``.

Coverage summary (what this file actually proves, and over which domain):

* ML-KEM ``q=3329``: **exhaustive** over the complete input domain of
  :func:`model.fastmod.reduce_kem`, i.e. every one of the ``2**24 =
  16,777,216`` values in ``[0, 2**24)``. That domain strictly contains every
  product of two canonical residues (``0 .. 3328*3328 = 11,075,584``), so the
  modular multiply is exhaustively correct for all ``3329**2 = 11,082,241``
  canonical operand pairs as a corollary. The exhaustive loop is the reason
  this file has a runtime budget; it takes roughly 15 s.
* ML-DSA ``q=8380417``: randomized with a fixed seed, plus boundary cases,
  plus a numeric check of every range bound the proof in ``reduce_dsa``
  depends on. Exhaustive is impossible here (``2**46`` inputs).
* Both: differential against ``model.modarith.mul_mod_shift_add``, the
  already-verified 24-cycle shift-add slice.
* Both: a structural constant-time check - the executed line trace of the
  reduction must be identical for every input.
"""

from __future__ import annotations

import random
import sys
import unittest
from collections import Counter

from model import fastmod
from model.fastmod import (
    KEM_CORR,
    KEM_K,
    KEM_M,
    MODULUS_ID_DSA,
    MODULUS_ID_KEM,
    Q_DSA,
    Q_KEM,
    dsa_fold,
    execute,
    k2red,
    kem_normalize,
    kred,
    kred2_norm,
    mulmod,
    mulmod_dsa,
    mulmod_kem,
    reduce_dsa,
    reduce_kem,
    request_is_valid,
)
from model.modarith import mul_mod_shift_add

KEM_PRODUCT_DOMAIN = 1 << 24
DSA_PRODUCT_DOMAIN = 1 << 46


class ModulusFormTests(unittest.TestCase):
    """The identities the two reductions are derived from."""

    def test_kem_modulus_is_proth(self) -> None:
        self.assertEqual(Q_KEM, KEM_K * (1 << KEM_M) + 1)

    def test_dsa_modulus_is_solinas(self) -> None:
        self.assertEqual(Q_DSA, (1 << 23) - (1 << 13) + 1)
        # 2**23 == 2**13 - 1 (mod q) is the folding rule.
        self.assertEqual((1 << 23) % Q_DSA, ((1 << 13) - 1) % Q_DSA)

    def test_kem_correction_constant_cancels_the_k2red_scaling(self) -> None:
        # K2RED scales by k**2 = 169 per application; the datapath applies it
        # twice, so the correction constant must invert 169**2.
        self.assertEqual((KEM_K**2) ** 2 * KEM_CORR % Q_KEM, 1)
        self.assertEqual(KEM_CORR, 1353)

    def test_kem_intermediate_stays_in_the_proven_domain(self) -> None:
        # kred2_norm requires its argument below 2**24; the second call's
        # argument is at most (q-1)*KEM_CORR.
        self.assertLess((Q_KEM - 1) * KEM_CORR, KEM_PRODUCT_DOMAIN)

    def test_canonical_products_fit_the_proven_domains(self) -> None:
        self.assertLess((Q_KEM - 1) ** 2, KEM_PRODUCT_DOMAIN)
        self.assertLess((Q_DSA - 1) ** 2, DSA_PRODUCT_DOMAIN)


class KemRangeTests(unittest.TestCase):
    """The output ranges the K-RED proof claims, checked numerically."""

    def test_first_kred_range_over_the_full_24_bit_domain(self) -> None:
        # kred(C) = 13*C0 - C1 is separable in (C0, C1), so scanning the
        # corners of the rectangle [0,255] x [0,65535] is exhaustive for the
        # extrema, and every pair is realisable by some C < 2**24.
        low = min(KEM_K * c0 - c1 for c0 in (0, 255) for c1 in (0, 65535))
        high = max(KEM_K * c0 - c1 for c0 in (0, 255) for c1 in (0, 65535))
        self.assertEqual((low, high), (-65535, 3315))
        # Witnesses, evaluated through the real function.
        self.assertEqual(kred(65535 << KEM_M), -65535)
        self.assertEqual(kred(255), 3315)

    def test_second_kred_range_over_the_whole_first_stage_image(self) -> None:
        # Exhaustive over the interval that provably contains the image of the
        # first fold: every integer in [-65535, 3315].
        values = [kred(x) for x in range(-65535, 3316)]
        self.assertEqual((min(values), max(values)), (-12, 3571))

    def test_k2red_scaling_identity(self) -> None:
        rng = random.Random(0xC0FFEE)
        for _ in range(20_000):
            c = rng.randrange(KEM_PRODUCT_DOMAIN)
            self.assertEqual(k2red(c) % Q_KEM, 169 * c % Q_KEM)
            # kred's exact integer identity: KRED(C) = k*C - q*floor(C/2**m).
            self.assertEqual(kred(c), KEM_K * c - Q_KEM * (c >> KEM_M))

    def test_normalize_is_canonical_over_its_whole_input_range(self) -> None:
        for x in range(-12, 3572):
            value = kem_normalize(x)
            self.assertTrue(0 <= value < Q_KEM, x)
            self.assertEqual(value, x % Q_KEM)

    def test_two_conditional_subtracts_are_necessary(self) -> None:
        # The largest normalize input reaches 3571 + q = 6900 > 2*q = 6658,
        # so a single conditional subtract would not be enough.
        self.assertGreater(3571 + Q_KEM, 2 * Q_KEM)
        self.assertLess(3571 + Q_KEM, 3 * Q_KEM)

    def test_kred2_norm_is_canonical_and_scaled(self) -> None:
        rng = random.Random(0x5EED)
        for _ in range(20_000):
            c = rng.randrange(KEM_PRODUCT_DOMAIN)
            value = kred2_norm(c)
            self.assertTrue(0 <= value < Q_KEM)
            self.assertEqual(value, 169 * c % Q_KEM)


class KemExhaustiveTests(unittest.TestCase):
    """The headline evidence: nothing is sampled here."""

    def test_reduce_kem_exhaustive_over_full_24_bit_domain(self) -> None:
        """Every value in ``[0, 2**24)`` reduces to exactly ``value % 3329``.

        The expected residue is carried as a rolling counter rather than
        recomputed with ``%`` so the loop measures the implementation, not
        CPython's modulo. Domain covered: ``0 <= product < 16777216``, which
        contains every canonical ML-KEM product ``0 .. 11075584``.
        """
        expected = 0
        failures = 0
        first_failure = None
        for product in range(KEM_PRODUCT_DOMAIN):
            if reduce_kem(product) != expected:
                failures += 1
                if first_failure is None:
                    first_failure = product
            expected += 1
            if expected == Q_KEM:
                expected = 0
        self.assertEqual(
            failures,
            0,
            f"{failures} mismatches, first at product={first_failure}",
        )

    def test_mulmod_kem_boundaries(self) -> None:
        edges = (0, 1, 2, 255, 256, 257, Q_KEM - 2, Q_KEM - 1)
        for a in edges:
            for b in edges:
                self.assertEqual(mulmod_kem(a, b), a * b % Q_KEM, (a, b))

    def test_mulmod_kem_rejects_non_canonical(self) -> None:
        for bad in (-1, Q_KEM, Q_KEM + 1, 1 << 23):
            with self.assertRaises(ValueError):
                mulmod_kem(bad, 1)
            with self.assertRaises(ValueError):
                mulmod_kem(1, bad)
        with self.assertRaises(TypeError):
            mulmod_kem(True, 1)


class DsaRangeTests(unittest.TestCase):
    """Every bound the four-fold Solinas proof relies on, checked numerically."""

    @staticmethod
    def _max_fold_output(bound: int) -> int:
        """Exact maximum of ``dsa_fold(c)`` over ``0 <= c < bound``.

        ``dsa_fold(c) = c0 + c1*8191`` with ``c = c1*2**23 + c0``. For a fixed
        ``c1`` the term is maximised by the largest admissible ``c0``, and only
        the top ``c1`` can be short of ``2**23 - 1``; every smaller ``c1``
        admits the full ``c0``. So the maximum is attained at ``c1_max`` or at
        ``c1_max - 1``, and checking those (plus ``c1 = 0``) is exact.
        """
        last = bound - 1
        c1_max = last >> 23
        candidates = []
        for c1 in {0, max(c1_max - 1, 0), c1_max}:
            c0 = min((1 << 23) - 1, last - (c1 << 23))
            if c0 < 0:
                continue
            candidates.append(dsa_fold((c1 << 23) + c0))
        return max(candidates)

    def test_fold_bound_chain(self) -> None:
        bounds = []
        bound = DSA_PRODUCT_DOMAIN
        for _ in range(4):
            bound = self._max_fold_output(bound) + 1
            bounds.append(bound - 1)
        self.assertEqual(
            bounds,
            [68_719_468_544, 75_472_897, 8_445_944, 8_388_607],
        )
        self.assertLess(bounds[0], 1 << 36)
        self.assertLess(bounds[1], 1 << 27)
        self.assertLess(bounds[2], 1 << 24)
        self.assertLess(bounds[3], 1 << 23)
        # One conditional subtract is necessary and sufficient at the end.
        self.assertLess(bounds[3], 2 * Q_DSA)
        self.assertGreaterEqual(bounds[3], Q_DSA)

    def test_fold_identity(self) -> None:
        rng = random.Random(0xD5A)
        for _ in range(20_000):
            c = rng.randrange(DSA_PRODUCT_DOMAIN)
            self.assertEqual(dsa_fold(c) % Q_DSA, c % Q_DSA)
            # Exact integer identity: fold(C) = C - q*floor(C/2**23).
            self.assertEqual(dsa_fold(c), c - Q_DSA * (c >> 23))
            self.assertGreaterEqual(dsa_fold(c), 0)


class DsaReductionTests(unittest.TestCase):
    def test_reduce_dsa_randomized_fixed_seed(self) -> None:
        rng = random.Random(0x1CA1_D5A)
        for _ in range(150_000):
            product = rng.randrange(DSA_PRODUCT_DOMAIN)
            self.assertEqual(reduce_dsa(product), product % Q_DSA, product)

    def test_reduce_dsa_boundary_windows(self) -> None:
        anchors = [
            0,
            1,
            Q_DSA,
            2 * Q_DSA,
            1 << 13,
            1 << 23,
            1 << 24,
            1 << 36,
            1 << 45,
            (Q_DSA - 1) ** 2,
            DSA_PRODUCT_DOMAIN,
        ]
        for anchor in anchors:
            for delta in range(-64, 65):
                product = anchor + delta
                if not 0 <= product < DSA_PRODUCT_DOMAIN:
                    continue
                self.assertEqual(reduce_dsa(product), product % Q_DSA, product)

    def test_mulmod_dsa_boundaries(self) -> None:
        edges = (
            0,
            1,
            2,
            (1 << 13) - 1,
            1 << 13,
            (1 << 22),
            Q_DSA - 2,
            Q_DSA - 1,
        )
        for a in edges:
            for b in edges:
                self.assertEqual(mulmod_dsa(a, b), a * b % Q_DSA, (a, b))

    def test_mulmod_dsa_randomized_fixed_seed(self) -> None:
        rng = random.Random(0xB0773_D5A)
        for _ in range(50_000):
            a = rng.randrange(Q_DSA)
            b = rng.randrange(Q_DSA)
            self.assertEqual(mulmod_dsa(a, b), a * b % Q_DSA, (a, b))

    def test_mulmod_dsa_rejects_non_canonical(self) -> None:
        for bad in (-1, Q_DSA, Q_DSA + 1, 1 << 24):
            with self.assertRaises(ValueError):
                mulmod_dsa(bad, 1)
            with self.assertRaises(ValueError):
                mulmod_dsa(1, bad)


class DifferentialTests(unittest.TestCase):
    """Fast path against the already-verified 24-cycle shift-add slice."""

    def test_matches_shift_add_reference(self) -> None:
        rng = random.Random(0xD1FF)
        for modulus in (Q_KEM, Q_DSA):
            for _ in range(4_000):
                a = rng.randrange(modulus)
                b = rng.randrange(modulus)
                self.assertEqual(
                    mulmod(a, b, modulus),
                    mul_mod_shift_add(a, b, modulus).value,
                    (a, b, modulus),
                )

    def test_unsupported_modulus_rejected(self) -> None:
        with self.assertRaises(ValueError):
            mulmod(1, 1, 17)


class RequestContractTests(unittest.TestCase):
    """The fail-closed behaviour the RTL implements."""

    def test_valid_requests(self) -> None:
        self.assertEqual(execute(MODULUS_ID_KEM, 3328, 3328), (1, False))
        self.assertEqual(
            execute(MODULUS_ID_DSA, Q_DSA - 1, Q_DSA - 1), (1, False)
        )

    def test_faulting_requests_return_zero(self) -> None:
        cases = [
            (2, 0, 0),
            (3, 1, 1),
            (MODULUS_ID_KEM, Q_KEM, 0),
            (MODULUS_ID_KEM, 0, Q_KEM),
            (MODULUS_ID_DSA, Q_DSA, 0),
            (MODULUS_ID_DSA, 0, Q_DSA),
            (MODULUS_ID_KEM, 1 << 23, 0),
        ]
        for modulus_id, a, b in cases:
            self.assertFalse(request_is_valid(modulus_id, a, b), (modulus_id, a, b))
            self.assertEqual(execute(modulus_id, a, b), (0, True), (modulus_id, a, b))

    def test_kem_operands_above_kem_q_fault_even_though_dsa_would_accept(self) -> None:
        self.assertTrue(request_is_valid(MODULUS_ID_DSA, 5000, 5000))
        self.assertFalse(request_is_valid(MODULUS_ID_KEM, 5000, 5000))


class ConstantTimeStructureTests(unittest.TestCase):
    """No data-dependent iteration count and no data-dependent control flow.

    The check is structural: run the reduction under a line tracer restricted
    to ``model/fastmod.py`` and require that wildly different inputs execute
    exactly the same multiset of source lines the same number of times. A
    data-dependent branch or loop would change that trace.
    """

    def _trace(self, function, argument: int) -> Counter:
        filename = fastmod.__file__
        counts: Counter = Counter()

        def tracer(frame, event, _arg):
            if frame.f_code.co_filename != filename:
                return None
            if event == "line":
                counts[frame.f_lineno] += 1
            return tracer

        previous = sys.gettrace()
        sys.settrace(tracer)
        try:
            function(argument)
        finally:
            sys.settrace(previous)
        return counts

    def test_reduce_kem_trace_is_input_independent(self) -> None:
        probes = [0, 1, 3328, 3329, 11_075_584, (1 << 24) - 1, 8_388_608]
        traces = [self._trace(reduce_kem, value) for value in probes]
        for trace in traces[1:]:
            self.assertEqual(trace, traces[0])
        self.assertTrue(traces[0])

    def test_reduce_dsa_trace_is_input_independent(self) -> None:
        probes = [
            0,
            1,
            Q_DSA - 1,
            Q_DSA,
            (1 << 23) - 1,
            (Q_DSA - 1) ** 2,
            DSA_PRODUCT_DOMAIN - 1,
        ]
        traces = [self._trace(reduce_dsa, value) for value in probes]
        for trace in traces[1:]:
            self.assertEqual(trace, traces[0])
        self.assertTrue(traces[0])


if __name__ == "__main__":
    unittest.main()
