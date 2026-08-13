# LCA-1 S0 Rev-A integration contract

Status: ready for independent T0 review, not RTL-frozen and not fabrication-ready  
Release ID: `LCA1-S0-REV-A`  
Contract date: 2026-08-13  
Machine-readable source: [`fabrication/rev_a_release.json`](../fabrication/rev_a_release.json)

## Decision

Rev-A is an accelerator-only OpenFrame user project. It is not the earlier
CPU/firmware SoC, and it is not a TEE. The host owns standardized-object parsing,
algorithm sequencing, keys, bridge policy, chain state, and any confidential-
compute boundary. The die exposes bounded NTT, Keccak-f[1600], modular arithmetic,
SRAM, self-test, error, abort, and zeroize operations.

The physical candidate is ChipFoundry's 15 mm2, 44-GPIO standard OpenFrame on
SKY130. The source template is pinned to commit
`ca732a645568d89efc9db3052eadeca47c60cf4d`. CI2612 is a planning target, not a
reservation or purchase commitment.

## Rev-A block boundary

```text
64-QFN / OpenFrame GPIO
          |
          v
  LCA-LINK-16 adapter ---- status / IRQ / fault / zeroize
          |
          +---- Keccak-f[1600] permutation
          +---- ML-KEM / ML-DSA NTT + INTT
          +---- dual-modulus arithmetic lane
          +---- 32 KiB compiled SRAM (64 KiB measured experiment)
```

No externally supplied message, signature, ciphertext, public key, or secret key
is retained as a complete object. The host streams only bounded primitive state:
one 256-coefficient polynomial, one 200-byte Keccak state, or an explicitly
addressed SRAM range.

## RTL cut-list

| Current artifact | Rev-A disposition | Silicon action |
| --- | --- | --- |
| `rtl/lca_butterfly.sv` | retain, reference only | Preserve differential/formal evidence; instantiate only if a measured implementation selects it. |
| `rtl/lca_chip_top.sv` | replace | Remove PicoRV32, firmware ROM, 512 KiB SRAM, and the whole-object frontend. |
| `rtl/lca_host_frontend.sv` | remove | It implements the obsolete whole-message command ABI and is outside the Rev-A netlist. |
| `rtl/lca_keccak_f1600.sv` | retain | Reverify load/read, reset, backpressure, abort, and zeroize through the new adapter. |
| `rtl/lca_modmul.sv` | retain, reference only | Keep the constant-iteration characterization path until integrated synthesis selects the arithmetic lane. |
| `rtl/lca_ntt_accel.sv` | modify | Preserve Level-3 behavior; add sequential stream control and deliberately harden coefficient storage. |
| `rtl/lca_ntt_zetas.svh` | retain | Pin generator and source hashes in the physical release. |
| `rtl/lca_secure_sram.sv` | replace in silicon | Keep as a simulation model; wrap the selected compiled SRAM for silicon. |

CI rejects any new `rtl/*.sv` or `rtl/*.svh` file until this table is updated in
the machine-readable manifest.

## LCA-LINK-16 shell interface

The package exports one synchronous 16-bit multiplexed link. The complete
GPIO-to-QFN map is in [`fabrication/rev_a_package.json`](../fabrication/rev_a_package.json)
and the generated [`rev_a_gpio_map.csv`](../fabrication/generated/rev_a_gpio_map.csv).

| GPIO | Signal | Direction | Meaning |
| ---: | --- | --- | --- |
| 0-15 | `host_d[15:0]` | bidirectional | Little-endian request or response halfword. |
| 16-23 | `host_addr[7:0]` | input | CSR halfword address or sequential channel selector. |
| 24 | `req_valid` | input | Host request is valid. |
| 25 | `req_ready` | output | Chip can accept a request. |
| 26 | `req_write` | input | `1` for host-to-chip; `0` for chip-to-host read request. |
| 27 | `req_last` | input | Final sequential write beat. Ignored for CSR and reads. |
| 28 | `rsp_valid` | output | Chip response is valid. |
| 29 | `rsp_ready` | input | Host can accept the response. |
| 30 | `rsp_last` | output | Final sequential read beat. |
| 31 | `irq` | output | Level interrupt for done or sticky error. |
| 32 | `tamper_n` | input | Active-low fail-safe tamper input. |
| 33 | `zeroize_req` | input | Synchronous full-zeroize request. |
| 34 | `busy` | output | Accelerator operation in progress. |
| 35 | `fault` | output | Sticky fail-closed error. |
| 36 | `zeroize_busy` | output | SRAM/engine scrub in progress. |
| 37 | `selftest_fail` | output | High until startup self-test passes; high again on failure. |
| 38 | `host_clk` | input | Only functional clock. QFN pin 22. |
| 39-43 | `reserved[4:0]` | disabled | Input and output buffers disabled; no hidden test mode. |

OpenFrame's dedicated `resetb_l` is derived from QFN pin 21 and is not consumed
from the GPIO budget.

### Electrical pad policy

- The external link uses 3.3 V CMOS pad thresholds (`ib_mode_sel=0`,
  `vtrip_sel=0`).
- Input-only pads use drive mode `001`, output enable high, and input enabled.
- Push-pull outputs use drive mode `110`, output enable low, and input disabled.
- `host_d` uses drive mode `110`, input enabled, and dynamic output enable.
- Unused pads use drive mode `000` with both buffers disabled.
- Output slew is slow by default. It can change only after routed timing,
  package parasitics, board stackup, and signal-integrity review exist.
- Analog enable/select/polarity and holdover are disabled.

These values follow the SKY130 I/O user-guide truth tables. They still require
gate-level and pad-level simulation in the pinned OpenFrame release.

### Cycle contract

1. A request is accepted on a rising `host_clk` edge only when
   `req_valid && req_ready` is true.
2. Request address, write direction, final-beat flag, and write data are stable
   for the entire setup/hold window of that edge.
3. A read accepts no data from `host_d`. The host releases every `host_d` line
   no later than the read-accept edge.
4. A read response appears no earlier than the following rising edge. The chip
   drives `host_d` only while `rsp_valid=1`.
5. Response data and `rsp_last` remain bit-stable while
   `rsp_valid && !rsp_ready`.
6. There is at most one outstanding read. `req_ready=0` while a response is
   pending, during reset/startup, and during zeroization.
7. A write produces no normal response. A rejected write latches `fault`, an
   error code, and `irq`; it does not mutate accelerator or SRAM state.
8. The host never drives `host_d` while `rsp_valid=1`. Bus-contention testing is
   mandatory at RTL, gate level, on the evaluation board, and in the fixture.

### Address classes

`0x00-0x3f` are little-endian 16-bit CSR addresses. `req_write` selects access
direction. `0x80-0x8b` are sequential data channels:

| Address | Channel | Direction | Exact transfer unit |
| ---: | --- | --- | ---: |
| `0x80` | NTT coefficient write | host to chip | 1,024 bytes |
| `0x82` | NTT coefficient read | chip to host | 1,024 bytes |
| `0x84` | Keccak state write | host to chip | 200 bytes |
| `0x86` | Keccak state read | chip to host | 200 bytes |
| `0x88` | SRAM write | host to chip | bounded by selected SRAM and cursor |
| `0x8a` | SRAM read | chip to host | bounded by selected SRAM and cursor |

For a sequential write, `req_last` marks the terminal beat. Address bit zero is
zero when both bytes are valid and one only when the low byte of the final beat
is valid. A one-byte marker on a non-final beat is an error. Exact NTT and
Keccak lengths are mandatory. Read cursors are initialized by CSR and each
accepted request returns one halfword.

### CSR map

| Address | Access | Name | Contract |
| ---: | --- | --- | --- |
| `0x00-0x01` | R | `IDENTITY` | `0x4c434131` (`LCA1`), low halfword first. |
| `0x02` | R | `ABI_VERSION` | `0x0001`. |
| `0x03` | R | `CAPABILITIES` | NTT variants, Keccak, arithmetic, SRAM variant, tamper, self-test. |
| `0x04` | R | `STATUS` | Bits below. |
| `0x05` | R | `ERROR_CODE` | Sticky first error since clear/reset. |
| `0x06` | R/W | `COMMAND` | Primitive command only. |
| `0x07` | W1P | `CONTROL` | Start, abort, clear, zeroize, cursor reset. |
| `0x08-0x09` | R/W | `STREAM_CURSOR` | Byte cursor; writes allowed only while idle. |
| `0x0a-0x0b` | R | `TRANSFER_COUNT` | Accepted bytes for the current sequential channel. |
| `0x0c` | R | `SELFTEST_STATUS` | Not-run, running, pass, or fail. |
| `0x0d-0x0e` | R | `MASK_REV` | OpenFrame mask-revision value. |

`STATUS` is frozen as:

| Bit | Name | Meaning |
| ---: | --- | --- |
| 0 | `READY` | Startup scrub and self-test passed and no tamper is latched. |
| 1 | `BUSY` | Primitive operation active. |
| 2 | `DONE` | Primitive completion latched. |
| 3 | `FAULT` | Sticky error latched. |
| 4 | `ZEROIZE_BUSY` | Engine/SRAM clear in progress. |
| 5 | `SELFTEST_PASS` | Startup or commanded self-test passed. |
| 6 | `RESPONSE_PENDING` | Read response is waiting for the host. |
| 7 | `TAMPER_LATCHED` | Tamper was observed; reset recovery is required. |
| 8 | `SRAM_SCRUBBED` | A complete scrub has finished since reset. |
| 15:9 | reserved | Read zero. Writes have no effect. |

`CONTROL` is write-one-pulse:

| Bit | Name | Rule |
| ---: | --- | --- |
| 0 | `START` | Validate selected primitive and staged length; accept only while ready and idle. |
| 1 | `ABORT` | Cancel, suppress output, and perform a complete selected-SRAM/engine scrub. |
| 2 | `CLEAR_DONE` | Clear done and non-tamper error only while idle. |
| 3 | `ZEROIZE_ALL` | Always honored; identical full scrub semantics to external zeroize. |
| 4 | `RESET_STREAM_CURSORS` | Clear cursors/counters only while idle. |

Commands are limited to ML-KEM NTT/INTT, ML-DSA NTT/INTT, Keccak-f[1600],
bounded modular arithmetic, and self-test. There is no decapsulation, signing,
verification, model execution, or other whole-algorithm command.

## Reset, abort, tamper, and zeroize

- `resetb_l` asserts control reset asynchronously and deasserts through a
  two-flop synchronizer. SRAM contents are treated as unknown after reset.
- After reset deassertion the chip enters full scrub. `req_ready=0`, `host_d` is
  high impedance, response and IRQ are suppressed, `zeroize_busy=1`, and
  `selftest_fail=1` until scrub and startup self-test pass.
- `tamper_n` feeds an asynchronously asserting sticky latch so visible outputs
  are suppressed even if the functional clock stops. Scrubbing resumes or
  begins when `host_clk` is present. A clockless die cannot physically rewrite
  SRAM; this is a documented Rev-A limitation, not a TEE claim.
- Tamper remains latched until reset followed by a complete scrub and self-test.
- Host zeroize and abort are synchronous but always win over ordinary
  transactions and operations. Both discard pending response data.
- `zeroize_busy` clears only after every selected SRAM bank, retained Keccak
  lane, NTT coefficient, arithmetic register, cursor, response register, and
  error field in the zeroize class is cleared.
- Verification must include reset during every engine phase, abort during every
  sequential channel phase, response backpressure, repeated tamper, clock stop
  during tamper, and zeroize at the first and last SRAM address.

## Memory decision

The baseline is one ChipFoundry `CF_SRAM_8192x32` macro: 32 KiB, published
area 1.34 mm2, Wishbone interface. The 64 KiB experiment uses two identical
instances and must be measured in the same pinned OpenFrame flow. The commercial
views, license, timing model, repair/test behavior, and exact bus latency are not
yet acquired, so neither variant is hardening-ready.

The 64 KiB experiment is promoted only if it closes area, all timing corners,
congestion, IR/EM, zeroize coverage, and commercial cost. It is not permission
to restore the removed 64 KiB whole-message frontend.

## Verification and physical release gates

| Gate | Required evidence |
| --- | --- |
| Interface | Cycle-accurate host model, randomized request/response backpressure, illegal access, odd-byte termination, and contention assertions. |
| Primitive | Independent known-answer and randomized differential tests through package-level transactions. |
| Reset/security control | Formal/RTL properties for safe outputs, sticky tamper, full address scrub, no request during scrub, and no stale response after abort. |
| Memory | Compiled macro model in RTL/GL tests, complete March test, macro timing, and zeroize across banks/repair structures. |
| Hardening | Pinned OpenFrame template, pinned PDK/tool containers, macro and wrapper GDS/LEF/LIB/SPEF/SDF, clean DRC/LVS/antenna, STA, IR/EM, and congestion evidence. |
| Full chip | RTL and gate-level OpenFrame simulations, wrapper pin-order match, power connection, and local `cf precheck`. |
| Release | Source, constraints, reports, logs, generated artifacts, GDSII, hashes, waivers, and approval identities archived together. |

## Review decision

T0 passes only when an independent reviewer records all of the following:

- every current RTL file has an explicit retain/modify/replace/remove decision;
- the old CPU, ROM, 512 KiB SRAM, and whole-message frontend cannot enter the
  Rev-A file list accidentally;
- the LCA-LINK-16 host model agrees cycle-for-cycle with this document;
- reset, abort, illegal access, tamper, clock loss, and zeroize are unambiguous;
- 32 KiB is the default and 64 KiB remains an experiment;
- the package/pad mapping matches the vendor-confirmed OpenFrame release;
- no TEE, private-inference, PPA, production-security, or full-algorithm claim
  is inferred from this boundary.

Until that review is recorded, the document is a controlled proposal, not an
RTL freeze.
