# SPDX-License-Identifier: Apache-2.0
"""Branch-free fast modular reduction reference for the LCA-1 production moduli.

This module is the executable specification for ``rtl/lca_modmul_fast.sv``. It
is deliberately *not* a replacement for :mod:`model.modarith`: the 24-cycle
shift-add slice in ``rtl/lca_modmul.sv`` stays the bit-serial reference and
regression anchor. This file describes a second, shallower datapath that is
specialised to exactly two moduli.

Scope and non-claims
--------------------
* Everything here is integer arithmetic on Python ``int``. It models an RTL
  datapath, it is not an ML-KEM or ML-DSA implementation.
* "Branch-free" here means **no data-dependent iteration count and no
  data-dependent control flow**: every conditional in this file is a two-input
  select written arithmetically (``d + (q & -borrow)``), which maps to a 2:1
  mux in hardware, not to a loop or an early exit. The number of operations is
  a compile-time constant for every input.
* No timing, power, or electromagnetic side-channel claim is made or implied.
  Constant-time here is a *structural* property of the algorithm, not a
  measured property of any implementation.

Contents
--------
``reduce_kem``   exact ``C mod 3329`` for every ``C`` in ``[0, 2**24)``
``reduce_dsa``   exact ``C mod 8380417`` for every ``C`` in ``[0, 2**46)``
``mulmod_kem``   exact ``(a*b) mod 3329`` for canonical ``a, b``
``mulmod_dsa``   exact ``(a*b) mod 8380417`` for canonical ``a, b``
``mulmod``       modulus-selected dispatcher matching the RTL request contract

References
----------
* K-RED / K2-RED for Proth-form moduli: Bisheh-Niasar, Azarderakhsh and
  Mozaffari-Kermani, "High-Speed NTT-based Polynomial Multiplication
  Accelerator for CRYSTALS-Kyber", ePrint 2021/563.
  https://eprint.iacr.org/2021/563.pdf
* Bertels, Turan, Verbauwhede et al., open CC0-1.0 Kyber butterfly Verilog and
  the range/correctness bugs they document in prior published reductions:
  https://github.com/axytho/KyberButterflyCollection
* Solinas reduction for q = 2**23 - 2**13 + 1 as documented for Adams Bridge:
  https://chipsalliance.github.io/caliptra-web/docs/2.1/hardware/adams_bridge_mldsa.html
"""

from __future__ import annotations

# --------------------------------------------------------------------------
# ML-KEM-768 field: q = 3329 = 13 * 2**8 + 1  (Proth form q = k * 2**m + 1)
# --------------------------------------------------------------------------

Q_KEM = 3329
KEM_K = 13
KEM_M = 8
#: 169**2 * KEM_CORR == 1 (mod 3329); see ``reduce_kem`` for the derivation.
KEM_CORR = 1353

# --------------------------------------------------------------------------
# ML-DSA-65 field: q = 8380417 = 2**23 - 2**13 + 1  (Solinas / pseudo-Mersenne)
# --------------------------------------------------------------------------

Q_DSA = 8_380_417
DSA_S = 23
DSA_T = 13

#: Modulus selector encoding shared with ``rtl/lca_modmul_fast.sv`` and
#: ``rtl/lca_butterfly.sv``: 0 -> ML-KEM, 1 -> ML-DSA, anything else faults.
MODULUS_ID_KEM = 0
MODULUS_ID_DSA = 1

#: Fixed, data-independent response latency of ``rtl/lca_modmul_fast.sv``:
#: clock edges from the accepting edge to the edge that asserts ``rsp_valid``.
#: Same measurement convention as the 24 recorded for the shift-add slice in
#: ``verification/vectors/butterfly_vectors.txt``.
FAST_LATENCY_CYCLES = 2
#: Registered pipeline stages in ``rtl/lca_modmul_fast.sv``.
FAST_PIPELINE_STAGES = 3
#: Latency of the shift-add slice it runs beside (``rtl/lca_modmul.sv``).
SHIFT_ADD_LATENCY_CYCLES = 24


def _cond_sub(value: int, modulus: int, width: int) -> int:
    """Branch-free conditional subtract: ``value - modulus`` if it stays >= 0.

    ``value`` must satisfy ``0 <= value < 2**width`` and ``modulus < 2**width``
    so that the difference stays inside ``(-2**width, 2**width)``. Then
    ``d >> width`` is ``-1`` exactly when ``d < 0``, which is the borrow bit of
    the same subtractor in hardware, and ``modulus & -borrow`` is the add-back
    term selected by that bit. No Python branch, no loop: this is one
    subtractor plus one 2:1 mux.
    """
    difference = value - modulus
    borrow = (difference >> width) & 1
    return difference + (modulus & -borrow)


# --------------------------------------------------------------------------
# ML-KEM: K-RED / K2-RED
# --------------------------------------------------------------------------


def kred(value: int) -> int:
    """One K-RED folding step for the Proth modulus ``q = k*2**m + 1``.

    Split ``C = C1 * 2**m + C0`` with ``C0 = C mod 2**m`` in ``[0, 2**m)`` and
    ``C1 = floor(C / 2**m)`` (an arithmetic shift, so this is also correct for
    negative ``C``). Define::

        KRED(C) = k*C0 - C1

    Exact algebraic identity (no congruence hand-waving)::

        KRED(C) = k*(C - C1*2**m) - C1
                = k*C - C1*(k*2**m + 1)
                = k*C - C1*q

    so ``KRED(C) == k*C (mod q)`` for every integer ``C``, and the difference
    from ``k*C`` is an exact integer multiple of ``q``. Only shifts, an
    add/subtract, and a multiply by the 4-bit constant ``k = 13`` are used;
    ``13*x == (x << 3) + (x << 2) + x``.

    Proven output ranges used by the caller:

    * ``0 <= C < 2**24``  ->  ``C0 in [0, 255]``, ``C1 in [0, 65535]``, so
      ``KRED(C) in [-65535, 3315]``. Both endpoints are attained
      (``C = 65535*256`` and ``C = 255``).
    * ``-65535 <= x <= 3315``  ->  ``C0 in [0, 255]``,
      ``C1 = floor(x/256) in [-256, 12]``, so ``KRED(x) in [-12, 3571]``.
      Both endpoints are attained.
    """
    return KEM_K * (value & ((1 << KEM_M) - 1)) - (value >> KEM_M)


def k2red(value: int) -> int:
    """Two chained K-RED steps: ``K2RED(C) == k**2 * C == 169*C (mod q)``.

    For ``0 <= C < 2**24`` the composed output range is ``[-12, 3571]``, from
    the two ranges proven in :func:`kred`.
    """
    return kred(kred(value))


def kem_normalize(value: int) -> int:
    """Map ``value`` in ``[-12, 3571]`` into the canonical range ``[0, 3329)``.

    Range proof:

    * ``value + q`` lands in ``[3317, 6900]``, which is non-negative and below
      ``3*q = 9987``, so it needs at most two conditional subtracts;
    * after the first conditional subtract the range is ``[0, 3571]``
      (inputs in ``[3317, 3328]`` pass through, inputs in ``[3329, 6900]``
      drop to ``[0, 3571]``);
    * after the second it is ``[0, 3328] == [0, q)``.

    Two conditional subtracts are necessary as well as sufficient: ``6900``
    exceeds ``2*q = 6658``.
    """
    shifted = value + Q_KEM
    shifted = _cond_sub(shifted, Q_KEM, 13)
    return _cond_sub(shifted, Q_KEM, 13)


def kred2_norm(value: int) -> int:
    """``normalize(K2RED(C))``: canonical in ``[0, q)`` and ``== 169*C (mod q)``.

    Requires ``0 <= value < 2**24``. This single function is the only reduction
    primitive the ML-KEM datapath uses; the RTL instantiates it twice.
    """
    return kem_normalize(k2red(value))


def reduce_kem(product: int) -> int:
    """Exact ``product mod 3329`` for every ``product`` in ``[0, 2**24)``.

    K2-RED is a Montgomery-style reduction: it returns a *scaled* residue
    ``169*C``, not ``C``. The scaling is removed with one extra constant
    multiply, chosen so the whole chain is exact:

    ``X = kred2_norm(C)``               -> ``X == 169*C (mod q)``, ``X < q``
    ``Y = kred2_norm(X * KEM_CORR)``    -> ``Y == 169*KEM_CORR*X (mod q)``

    so ``Y == 169**2 * KEM_CORR * C (mod q)``, and ``KEM_CORR = 1353`` is
    picked so that ``169**2 * 1353 == 1 (mod 3329)`` (checked in the tests).
    Hence ``Y == C (mod q)`` and ``Y`` is canonical, i.e. ``Y == C mod q``.

    Domain safety of the second call: ``X <= 3328`` and
    ``3328 * 1353 == 4502784 < 2**24``, so the ``[0, 2**24)`` precondition of
    :func:`kred2_norm` holds for both invocations.

    Cost: two K2-RED chains (shifts, adds, and multiplies by the constant 13)
    plus one multiply by the sparse constant
    ``1353 = 2**10 + 2**8 + 2**6 + 2**3 + 2**0``.

    Verified exhaustively over the whole ``[0, 2**24)`` domain in
    ``tests/test_fastmod.py``, which strictly contains every product of two
    canonical ML-KEM residues (``0 .. 3328*3328``).
    """
    scaled = kred2_norm(product)
    return kred2_norm(scaled * KEM_CORR)


def mulmod_kem(a: int, b: int) -> int:
    """Exact ``(a*b) mod 3329`` for canonical ``a, b`` in ``[0, 3329)``."""
    _require_canonical(a, Q_KEM, "a")
    _require_canonical(b, Q_KEM, "b")
    return reduce_kem(a * b)


# --------------------------------------------------------------------------
# ML-DSA: Solinas folding
# --------------------------------------------------------------------------


def dsa_fold(value: int) -> int:
    """One Solinas folding step for ``q = 2**23 - 2**13 + 1``.

    From ``q = 2**23 - 2**13 + 1`` we get the reduction rule::

        2**23 == 2**13 - 1  (mod q)

    Split ``C = C1 * 2**23 + C0`` with ``C0 = C mod 2**23`` and
    ``C1 = floor(C / 2**23)``. Substituting the rule::

        C == C0 + C1*(2**13 - 1) == C0 + (C1 << 13) - C1   (mod q)

    Exactly as with K-RED this is an exact integer identity up to a multiple of
    ``q``: ``fold(C) = C - C1*q``. Both terms are non-negative for
    non-negative ``C``, so the hardware needs no sign handling: one shift, one
    add and one subtract.
    """
    low = value & ((1 << DSA_S) - 1)
    high = value >> DSA_S
    return low + (high << DSA_T) - high


def reduce_dsa(product: int) -> int:
    """Exact ``product mod 8380417`` for every ``product`` in ``[0, 2**46)``.

    Four folds followed by one conditional subtract. Each bound below is the
    worst case of ``fold(C) = C0 + C1*8191 <= (2**23 - 1) + C1*8191`` given the
    previous bound, and each is checked numerically in ``tests/test_fastmod.py``:

    ======  ============================  ============================
    step    exact worst-case output       fits under
    ======  ============================  ============================
    input   ``2**46 - 1``                 ``2**46 = 70368744177664``
    fold 1  ``68719468544``               ``2**36 = 68719476736``
    fold 2  ``75472897``                  ``2**27 = 134217728``
    fold 3  ``8445944``                   ``2**24 = 16777216``
    fold 4  ``8388607``                   ``2**23 = 8388608``
    ======  ============================  ============================

    The fold-1 bound is tight: it clears ``2**36`` by only 8192, which is why
    the table is machine-checked rather than asserted in prose.

    Fold 4 is the interesting one: if the incoming value is below ``2**23`` it
    passes through unchanged (at most ``8388607``); otherwise its high part is
    exactly ``1`` and its low part is at most ``57336``, giving at most
    ``65527``. Either way the result is at most ``8388607``.

    Since ``8388607 = q + 8190 < 2*q``, exactly one conditional subtract is
    necessary and sufficient to land in ``[0, q)``.

    ``(q-1)**2 == 70231372333056 < 2**46``, so every product of two canonical
    ML-DSA residues is inside the proven domain.
    """
    folded = dsa_fold(dsa_fold(dsa_fold(dsa_fold(product))))
    return _cond_sub(folded, Q_DSA, 24)


def mulmod_dsa(a: int, b: int) -> int:
    """Exact ``(a*b) mod 8380417`` for canonical ``a, b`` in ``[0, 8380417)``."""
    _require_canonical(a, Q_DSA, "a")
    _require_canonical(b, Q_DSA, "b")
    return reduce_dsa(a * b)


# --------------------------------------------------------------------------
# Request-level dispatcher, matching the RTL contract
# --------------------------------------------------------------------------


def _require_canonical(value: int, modulus: int, name: str) -> None:
    if not isinstance(value, int) or isinstance(value, bool):
        raise TypeError(f"{name} must be an integer")
    if not 0 <= value < modulus:
        raise ValueError(f"{name}={value} is not canonical for q={modulus}")


def modulus_for_id(modulus_id: int) -> int:
    """Return the modulus a request selector encodes, or raise on a bad id."""
    if modulus_id == MODULUS_ID_KEM:
        return Q_KEM
    if modulus_id == MODULUS_ID_DSA:
        return Q_DSA
    raise ValueError(f"unsupported modulus id: {modulus_id}")


def mulmod(a: int, b: int, modulus: int) -> int:
    """Exact ``(a*b) mod modulus`` for the two supported production moduli."""
    if modulus == Q_KEM:
        return mulmod_kem(a, b)
    if modulus == Q_DSA:
        return mulmod_dsa(a, b)
    raise ValueError(f"unsupported modulus: {modulus}")


def request_is_valid(modulus_id: int, a: int, b: int) -> bool:
    """Model the RTL's fail-closed input check.

    The RTL faults - and drives a zero product - when the selector is not one
    of the two supported ids, or when either operand is non-canonical for the
    selected modulus. It never starts a partial or shortened computation: the
    response latency is the same on the fault path.
    """
    if modulus_id not in (MODULUS_ID_KEM, MODULUS_ID_DSA):
        return False
    modulus = modulus_for_id(modulus_id)
    return 0 <= a < modulus and 0 <= b < modulus


def execute(modulus_id: int, a: int, b: int) -> tuple[int, bool]:
    """Return ``(product, fault)`` exactly as ``rtl/lca_modmul_fast.sv`` does."""
    if not request_is_valid(modulus_id, a, b):
        return 0, True
    return mulmod(a, b, modulus_for_id(modulus_id)), False
