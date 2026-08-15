# SPDX-License-Identifier: Apache-2.0
"""Bit-exact reference model for the first LCA-1 RTL slice.

This is not an ML-KEM or ML-DSA implementation. It models the shared modular
multiply and butterfly primitive implemented in ``rtl/``.
"""

from __future__ import annotations

from dataclasses import dataclass

KEM_Q = 3329
DSA_Q = 8_380_417
WORD_BITS = 24
SUPPORTED_MODULI = (KEM_Q, DSA_Q)


def _validate_modulus(modulus: int) -> None:
    if modulus not in SUPPORTED_MODULI:
        raise ValueError(f"unsupported modulus: {modulus}")
    if modulus >= (1 << (WORD_BITS - 1)):
        raise ValueError("modulus does not fit the signed-safety design bound")


def _validate_residue(value: int, modulus: int, name: str) -> None:
    if not isinstance(value, int):
        raise TypeError(f"{name} must be an integer")
    if not 0 <= value < modulus:
        raise ValueError(f"{name}={value} is not canonical for q={modulus}")


def add_mod(a: int, b: int, modulus: int) -> int:
    """Return ``a+b mod q`` for canonical residues using one subtraction."""
    _validate_modulus(modulus)
    _validate_residue(a, modulus, "a")
    _validate_residue(b, modulus, "b")
    total = a + b
    return total - modulus if total >= modulus else total


def sub_mod(a: int, b: int, modulus: int) -> int:
    """Return ``a-b mod q`` for canonical residues."""
    _validate_modulus(modulus)
    _validate_residue(a, modulus, "a")
    _validate_residue(b, modulus, "b")
    return a - b if a >= b else a + modulus - b


@dataclass(frozen=True)
class MulResult:
    value: int
    cycles: int


def mul_mod_shift_add(
    a: int,
    b: int,
    modulus: int,
    *,
    word_bits: int = WORD_BITS,
) -> MulResult:
    """Constant-iteration modular multiply matching ``lca_modmul.sv``.

    The loop count depends only on the public datapath width, never on operand
    values. Inputs and every intermediate are canonical residues.
    """
    _validate_modulus(modulus)
    _validate_residue(a, modulus, "a")
    _validate_residue(b, modulus, "b")
    if word_bits < WORD_BITS:
        raise ValueError(f"word_bits must be at least {WORD_BITS}")

    product = 0
    multiplicand = a
    multiplier = b
    for _ in range(word_bits):
        if multiplier & 1:
            product = add_mod(product, multiplicand, modulus)
        multiplicand = add_mod(multiplicand, multiplicand, modulus)
        multiplier >>= 1

    return MulResult(value=product, cycles=word_bits)


@dataclass(frozen=True)
class ButterflyResult:
    out_a: int
    out_b: int
    product: int
    cycles: int


def butterfly(a: int, b: int, twiddle: int, modulus: int) -> ButterflyResult:
    """Compute ``(a+b*w, a-b*w) mod q`` like the v0 RTL slice."""
    _validate_residue(a, modulus, "a")
    _validate_residue(b, modulus, "b")
    _validate_residue(twiddle, modulus, "twiddle")
    product = mul_mod_shift_add(b, twiddle, modulus)
    return ButterflyResult(
        out_a=add_mod(a, product.value, modulus),
        out_b=sub_mod(a, product.value, modulus),
        product=product.value,
        cycles=product.cycles,
    )
