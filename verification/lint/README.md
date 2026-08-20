<!-- SPDX-License-Identifier: Apache-2.0 -->

# Verilator lint: an independent second front-end

The E1 evidence chain reads the RTL with exactly two front-ends: Icarus
Verilog (`make rtl-test`) and Yosys (`make formal`, `make synth`). Both are
permissive about implicit width changes and neither performs unused-signal or
dead-parameter analysis. A defect that both accept is invisible to every layer
in `spec/VERIFICATION_PLAN.md`.

Verilator is a third, unrelated SystemVerilog front-end with an aggressive
static-analysis pass. This directory runs it over the same sources purely as a
cross-check. It compiles nothing and simulates nothing.

```bash
bash verification/lint/run_lint.sh
```

Verilator is not a repository prerequisite. If it is missing the script prints
a `SKIP` notice with the install command and exits 0 — an absent cross-check is
reported, never silently converted into a pass.

## Two tiers

| Tier | Scope | Behavior |
|---|---|---|
| gating | `rtl/lca_modmul.sv` + `rtl/lca_butterfly.sv`, elaborated as a hierarchy with `-Wall` | must be warning-free under `waivers.vlt`; any new finding exits 1 |
| advisory | every other `rtl/*.sv` | findings are printed and analyzed below; never waived, never gating |

The split follows the repository's own boundary: the v0 arithmetic slice is
the only claims-bearing datapath, and the Rev-A candidates
(`lca_ntt_accel.sv`, `lca_chip_top.sv`, `lca_host_frontend.sv`,
`lca_modmul_fast.sv`) sit outside the E1 evidence chain. Holding them to a
gating standard today would either block work on them or push their real
findings under a waiver, and the second-front-end value is in reading the
findings, not in suppressing them.

The gating set is written out explicitly in `run_lint.sh` rather than globbed.
Which modules carry claims is a decision; it must not silently change when a
file is added to `rtl/`.

## Measured baseline

Verilator 5.020 2024-01-01 (Debian 5.020-1), measured 2026-08-16 in the
development container against the working tree at that time.

```text
== gating tier: E1 evidence slice (top lca_butterfly) ==
PASS: E1 evidence slice is Verilator-clean under the recorded waivers.
```

Advisory line numbers below are from that run; the Rev-A sources are under
active development and their line numbers drift.

## Waivers (gating tier)

Four `-Wall` findings in the E1 slice. All four are width-related and all four
are provably benign, so they are waived in `waivers.vlt` — pinned to an exact
file, rule, and line so that editing or moving the code re-raises the warning
instead of inheriting the waiver.

| Rule | Site | Why it is safe |
|---|---|---|
| `WIDTHTRUNC` | `lca_modmul.sv:41`, `lca_butterfly.sv:48` | `add_mod()` computes `sum` at `WORD_BITS+1` bits so the unreduced sum cannot wrap. The 25-bit `sum - q` is only evaluated when `sum >= q`, and both inputs are below `q`, so the result is `< q < 2**WORD_BITS`: the discarded bit is always 0. This is the standard conditional-subtract idiom and the exhaustive four-bit formal proof at `q=13` covers exactly this function. |
| `WIDTHEXPAND` | `lca_modmul.sv:81` | `count == WORD_BITS - 1` compares the 5-bit counter against the elaboration-time integer 23. Verilog zero-extends `count` to 32 bits; 23 is representable, so the comparison is exact. The `ifdef FORMAL` block already asserts the same bound with an explicit `COUNT_BITS'` cast, and the counter bound is closed by temporal induction (invariant I3). |
| `UNUSEDSIGNAL` | `lca_butterfly.sv:59` | `sub_mod()` declares `difference` at `WORD_BITS+1` bits, but the wide form is only evaluated on the `x < y` branch where `x + q - y < q < 2**WORD_BITS`. Bit `WORD_BITS` is provably 0 and is intentionally not read. The precondition (`x`, `y` both canonical) is enforced by the fail-closed request validation and by the multiplier's own output range. |

No behavioral rule (`LATCH`, `CASEINCOMPLETE`, `ALWCOMBORDER`, `MULTIDRIVEN`,
`UNDRIVEN`, `BLKSEQ`, `COMBDLY`) is waived, and none fired.

## Advisory findings

Nothing here is claimed as a defect. These are the items a second front-end
surfaced that Icarus and Yosys accept silently, recorded so the Rev-A work can
dispose of them deliberately.

### `lca_ntt_accel.sv` — two `BLKLOOPINIT` errors (the substantive finding)

```text
%Error-BLKLOOPINIT: rtl/lca_ntt_accel.sv:167:28: Unsupported: Delayed assignment to array inside for loops (non-delayed is ok - see docs)
%Error-BLKLOOPINIT: rtl/lca_ntt_accel.sv:179:28: Unsupported: Delayed assignment to array inside for loops (non-delayed is ok - see docs)
```

Both are the 256-entry coefficient-array clear in the reset and `zeroize_i`
branches (`for (i = 0; i < 256; i = i + 1) coeff_q[i] <= 32'sd0;`). Icarus and
Yosys both accept it. Verilator refuses to elaborate the module at all.

Two consequences worth recording:

1. The Verilator coverage tier proposed in `docs/IMPROVEMENT_PLAN.md` §5
   cannot be pointed at the Rev-A NTT engine as written. This is a concrete,
   measured blocker on a planned item, not a style preference.
2. The construct is a single-cycle synchronous clear of 256 32-bit registers.
   Whatever the simulator thinks, that is 8192 flops resetting in one cycle,
   which is a SKY130 hardening and zeroize-timing question the Rev-A work
   already owns.

### `lca_ntt_accel.sv:127` — context-width sign-extension in the INTT subtract

```text
%Warning-WIDTHEXPAND: rtl/lca_ntt_accel.sv:127:50: Operator SUB expects 64 bits on the LHS, but LHS's VARREF 'a_value' generates 32 bits.
```

`wide_product = zeta_q * (a_value - b_value);` — because the assignment target
is 64 bits, Verilog's context-determined width rule evaluates `a_value -
b_value` at 64 bits. The PQClean ML-DSA reference this mirrors performs that
subtraction in `int32_t` and only then widens, so the two differ exactly when
`a - b` would overflow `int32_t`. The reference relies on coefficient bounds to
prevent that, so this is very likely benign — but "very likely" is the wrong
standard for an arithmetic core, and it should be discharged by a bounds
argument or a differential test before the Rev-A engine enters any evidence
chain. Reference-mirroring RTL is precisely where a silent width promotion
does damage.

### Remaining advisory items (reviewed, no action proposed)

- `lca_ntt_accel.sv:74/85/95` `WIDTHTRUNC`/`WIDTHEXPAND`: the intended
  truncations in the Montgomery and Barrett reductions (`>>> 32`, `>>> 16`,
  and the Barrett fixup), matching the reference's cast to the narrow type.
- `lca_ntt_accel.sv:59` `UNUSEDSIGNAL` on `butterfly_peer[8]`: a 9-bit index
  whose top bit is carry headroom.
- `lca_chip_top.sv:192/287/318/477` and `lca_host_frontend.sv:193/200`:
  byte-to-word address arithmetic done in 32-bit integer context and assigned
  to narrow address buses. Benign, but each one is an address truncation that
  no current test exercises at its boundary.
- `lca_host_frontend.sv:24/28/29` `UNUSEDSIGNAL`: byte-lane address bits and
  the upper `pwdata_i`/`pstrb_i` bits of a 32-bit APB write port used as an
  8-bit register file. Expected for this interface style.
- `lca_host_frontend.sv:99` `UNUSEDPARAM` on `RESULT_INVALID_SIGNATURE`: an
  8'h01 status code declared in RTL but never driven by RTL — the code arrives
  from firmware over `fw_result_code_i`. Harmless, but it is an ABI-visible
  constant with no RTL producer, so it belongs in the CSR/status contract
  rather than as a dead localparam.
- `lca_modmul_fast.sv` `UNUSEDSIGNAL` on `stage_b_kem[31:12]`,
  `stage_c_kem[31:12]` and `stage_c_dsa[47:24]`: unread high bits of the
  KEM-width intermediates in a datapath shared with the wider DSA modulus.
  (No line numbers here: that file is under active development and they
  move; the signal names do not.)
- `lca_chip_top.sv` also reports `Cannot find file containing module` for
  `picorv32` and `lca_core`. Those live in a submodule and outside `rtl/`
  respectively; the module is not standalone-elaborable and that is expected.

## Claim boundary

- Lint is a static cross-check. It proves nothing about functional
  correctness, timing, area, power, or security.
- The gating tier passing means "no unwaived Verilator `-Wall` finding in the
  two E1 modules at this commit", nothing more.
- Verilator version drift changes the finding set. The version is printed on
  every run and quoted above so a differing result is attributable.
- This pass is not part of `make verify` and is not an E1 gate.
