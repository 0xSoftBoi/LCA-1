"""Dependency-free LCA-1 arithmetic reference model.

The functions here are deliberately small and boring. They are an executable
description of the RTL contract, not an independent implementation of ML-KEM
or ML-DSA.
"""

from __future__ import annotations

Q_MLDSA = 8_380_417
Q_MLKEM = 3_329

OP_MUL = 0
OP_CT = 1
OP_GS = 2


def modulus(mode_kem: bool) -> int:
    """Return the FIPS field modulus selected by the hardware mode."""
    return Q_MLKEM if mode_kem else Q_MLDSA


def _require_canonical(value: int, q: int, name: str) -> None:
    if not 0 <= value < q:
        raise ValueError(f"{name}={value} is not canonical for q={q}")


def modmul(a: int, b: int, q: int) -> int:
    """Model the RTL's fixed-24-step add/double modular multiplier."""
    _require_canonical(a, q, "a")
    _require_canonical(b, q, "b")

    accumulator = 0
    multiplicand = a
    multiplier = b
    for _ in range(24):
        if multiplier & 1:
            accumulator += multiplicand
            if accumulator >= q:
                accumulator -= q
        multiplicand <<= 1
        if multiplicand >= q:
            multiplicand -= q
        multiplier >>= 1
    return accumulator


def ct_butterfly(a: int, b: int, zeta: int, q: int) -> tuple[int, int]:
    """Cooley-Tukey butterfly used by a forward NTT stage."""
    _require_canonical(a, q, "a")
    _require_canonical(b, q, "b")
    _require_canonical(zeta, q, "zeta")
    t = modmul(b, zeta, q)
    return (a + t) % q, (a - t) % q


def gs_butterfly(a: int, b: int, zeta: int, q: int) -> tuple[int, int]:
    """Gentleman-Sande butterfly used by an inverse NTT stage."""
    _require_canonical(a, q, "a")
    _require_canonical(b, q, "b")
    _require_canonical(zeta, q, "zeta")
    return (a + b) % q, modmul((a - b) % q, zeta, q)


def execute(op: int, mode_kem: bool, a: int, b: int, zeta: int = 0) -> tuple[int, int]:
    """Execute one LCA-1 command using the same public contract as RTL."""
    q = modulus(mode_kem)
    if op == OP_MUL:
        return modmul(a, b, q), 0
    if op == OP_CT:
        return ct_butterfly(a, b, zeta, q)
    if op == OP_GS:
        return gs_butterfly(a, b, zeta, q)
    raise ValueError(f"unsupported opcode: {op}")

