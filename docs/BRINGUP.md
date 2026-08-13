# Tiny arithmetic-lane first-silicon bring-up

This procedure applies only to `tt_um_suwappu_lattice_accel`, the small
arithmetic characterization vehicle. The full bridge SoC uses
`lca_chip_top` and the APB/stream ABI in [`COMMAND_ABI.md`](COMMAND_ABI.md).

Bring-up must use public known-answer coefficients only. Do not connect bridge
keys or production decapsulation traffic to first silicon.

## Host sanity checks

1. Hold `rst_n=0` for at least four clocks, then release it synchronously with
   a stable clock.
2. Confirm `uio_oe == 0xE0`; only status pins 7:5 may drive the bidirectional
   pads.
3. Read address `0x0` and expect `0x90` after reset: presence bit set, hardware
   major version 1, opcode 0, ML-DSA mode.
4. Confirm `busy=done=error=0`.

## Known-answer smoke vectors

All numbers below are decimal canonical field elements.

| profile | `a` | `b` | `zeta` | opcode | expected `(out0, out1)` |
| --- | ---: | ---: | ---: | --- | ---: |
| ML-KEM (`q=3329`) | 123 | 456 | 789 | multiply | `(2824, 0)` |
| ML-KEM (`q=3329`) | 123 | 456 | 789 | CT | `(375, 3200)` |
| ML-KEM (`q=3329`) | 123 | 456 | 789 | GS | `(579, 254)` |
| ML-DSA (`q=8380417`) | 1234567 | 7654321 | 1753 | multiply | `(5524390, 0)` |
| ML-DSA (`q=8380417`) | 1234567 | 7654321 | 1753 | CT | `(2211663, 257471)` |
| ML-DSA (`q=8380417`) | 1234567 | 7654321 | 1753 | GS | `(508471, 1071269)` |

Each accepted command should expose latched `done` after the same 32-cycle RTL
latency. Writing coefficient `q` itself, or opcode `11`, must return zero
outputs with `error=1`.

## Characterization ladder

1. Run reset and known-answer tests at the shuttle's conservative clock.
2. Sweep clock frequency while holding voltage and temperature constant.
3. Sweep supported voltage/temperature points at a known-good clock.
4. Run long deterministic randomized vectors against the software model.
5. Capture current and, where available, near-field EM traces for public input
   classes to quantify data-dependent switching.
6. Exercise reset during idle, launch, and multiply states; require clean
   recovery and a fresh known-answer pass.
7. Archive die ID, board revision, conditions, vector seed, failures, and raw
   traces together.

Any mismatch, timeout, unknown ID, or error on a canonical vector is a hard
failure. Characterization data may inform LCA-2 but must not be used to promote
LCA-1 into a production secret-bearing role.
