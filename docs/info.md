# LCA-1 Tiny Tapeout companion datasheet

This page documents the byte-programmed arithmetic characterization wrapper,
`tt_um_suwappu_lattice_accel`. It is retained alongside the full
`lca_chip_top` design but is not the full bridge chip. See
[`../README.md`](../README.md) for the complete SoC and
[`COMMAND_ABI.md`](COMMAND_ABI.md) for its APB/stream interface.

The small shuttle vehicle implements one constant-iteration modular multiplier
and NTT butterfly datapath. It intentionally contains no CPU, secure SRAM,
Keccak engine, private-key store, or complete FIPS 203/204 command.

## How it works

The host programs canonical field elements through an 8-bit register bus. A
start transaction atomically captures those registers, then a fixed-iteration
dual-modulus datapath executes modular multiply or one NTT butterfly. Latched
status pins let a slow controller observe completion.

## How to test

1. Write three little-endian bytes of `a` to addresses `0x1..0x3`.
2. Write `b` to `0x4..0x6`.
3. For butterfly opcodes, write `zeta` to `0x7..0x9`.
4. Write control address `0x0` with bit 7 set, opcode in bits 2:1, and
   `mode_kem` in bit 0.
5. Wait until `uio[5]` (`busy`) deasserts and `uio[6]` (`done`) asserts.
6. Read `out0` from `0xA..0xC` and `out1` from `0xD..0xF`.
7. If `uio[7]` is high, discard the outputs; an opcode or coefficient was
   invalid.

All coefficients must already be canonical for the selected field.

Reading address `0x0` returns a presence bit in bit 7, hardware major version
`1` in bits 6:4, and the currently programmed opcode/mode in bits 2:0.

Public known-answer vectors and the first-silicon characterization sequence are
in [`BRINGUP.md`](BRINGUP.md).

## External hardware

No external peripherals are required beyond a clocked host capable of driving
the Tiny Tapeout byte interface.
