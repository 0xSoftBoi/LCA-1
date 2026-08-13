# LCA-1 immutable firmware

## Role

The firmware is the algorithm control plane for the full chip. It boots at
`0x0000_0000`, clears its BSS, waits on the mailbox, claims one host command,
invokes a pinned Level-3 clean API, writes the result, and returns to the wait
loop. It has no scheduler, interrupts, filesystem, network stack, dynamic code
loading, or external debug protocol.

The shipped command image implements only:

- `PQCLEAN_MLDSA65_CLEAN_crypto_sign_verify_ctx`;
- `PQCLEAN_MLKEM768_CLEAN_crypto_kem_dec`;
- a SHAKE256 empty-string known-answer self-test.

Key generation, encapsulation, and signing sources are not linked into the ROM
image.

## Dependency pins

The repository records both dependencies as Git submodules:

| dependency | pinned commit | use |
| --- | --- | --- |
| PQClean | `0586a824fc0d49df0b6b6e9179d8d15d06d0974f` | ML-KEM-768 and ML-DSA-65 clean code |
| PicoRV32 | `a473fc8fca393771d83b0ffcf0b14db3393339d8` | RV32 control CPU |

The pin makes simulation and firmware builds reproducible. It is not an audit
or certification statement.

## Hardware adapters

Most PQClean algorithm files are compiled unchanged. Three pieces are replaced
at link time:

| firmware file | replaces/provides | behavior |
| --- | --- | --- |
| `fips202_lca.c` | `common/fips202.c` | keeps sponge logic in C; offloads each Keccak-f[1600] permutation through MMIO |
| `ntt_mmio.c` | ML-KEM and ML-DSA `ntt.c` entry points | moves 256 coefficients through the shared NTT window and waits for fixed-schedule completion |
| `runtime.c` | libc and `randombytes` boundary | freestanding memory functions, bounded FIPS 202 context allocator, external entropy reader |

ML-KEM base multiplication remains in `ntt_mmio.c` because the clean algorithm
performs it on two-coefficient NTT-domain pairs outside the full transforms.

## CPU and ABI

The image targets little-endian `riscv32-freestanding` with `RV32IMC` and the
`ilp32` ABI. The PicoRV32 instance enables compressed instructions, multiply,
and divide, matching the image attributes. The firmware uses polling MMIO;
PicoRV32 interrupts are disabled.

Mailbox registers visible to firmware:

| address | access | meaning |
| --- | --- | --- |
| `0x2000_0000` | R/W | present/pending/busy status; write bit 0 to claim |
| `0x2000_0004` | R/W | command on read; final result code on write |
| `0x2000_0008` | R/W | message length on read; result length on write |
| `0x2000_000c` | R | context length |
| `0x2000_0010` | R | loaded-object mask |
| `0x2000_001c` | R | external entropy word valid |
| `0x2000_0020` | R | entropy word; read consumes it |
| `0x2000_0040..5c` | W | eight result words |

Writing the result code is the commit point. The hardware pulses completion on
that write, so firmware must write all result words and the result length first.

## Memory layout

The linker gives firmware the lower 384 KiB of secure SRAM:

| region | address/range |
| --- | --- |
| ROM text and constants | `0x0000_0000..0x0003_ffff` |
| data/BSS/stack/work RAM | `0x1000_0000..0x1005_ffff` |
| initial stack pointer | `0x1006_0000` (grows downward) |
| host buffers | `0x1006_0000..0x1007_ffff` |

The current linked image contains 8,946 bytes of text, 288 bytes of read-only
data, no initialized data, and 6,660 bytes of BSS. Its raw ROM binary is 9,236
bytes. Algorithm stack use is additional and remains below the 384 KiB work
region in whole-chip simulation.

The minimal allocator contains 32 fixed 208-byte slots for FIPS 202 contexts.
Allocation failure terminates the active command with an internal error. Every
freed slot is overwritten before reuse.

## Build

Initialize submodules, then run:

```bash
make firmware ZIG=zig
```

The Makefile invokes Zig's Clang frontend with:

- target `riscv32-freestanding`;
- CPU features `generic_rv32+m+c`;
- `-Os`, freestanding/no-builtin/no-stack-protector;
- function/data sections and linker garbage collection;
- `firmware/linker.ld` and no host C runtime.

Outputs are ignored build artifacts:

| file | purpose |
| --- | --- |
| `build/firmware/lca_firmware.elf` | linked/debuggable image |
| `build/firmware/lca_firmware.bin` | raw ROM bytes |
| `build/firmware.hex` | little-endian 32-bit `$readmemh` image used by RTL |

`tools/bin_to_memhex.py` pads the final partial word with zero bytes and emits
one eight-hex-digit word per line.

## Command behavior

ML-DSA verification passes the exact fixed signature length, message length,
context length, and public key to the context-aware API. A return value of zero
becomes `RESULT_OK`; a nonzero verification result becomes
`RESULT_INVALID_SIGNATURE`.

ML-KEM decapsulation always returns 32 bytes. The clean implementation performs
implicit rejection for an invalid ciphertext and returns a pseudorandom secret
rather than an error oracle. Firmware clears its stack copy after transferring
the eight result words.

The self-test computes SHAKE256 with empty input and compares 32 bytes with the
known digest beginning `46 b9 dd 2b`. Because the FIPS 202 adapter is built with
`LCA_MMIO_ACCEL`, this test exercises CPU boot, SRAM, MMIO, the Keccak engine,
and result completion together.

## Verification and release discipline

`make test-soc` compiles a complete CXXRTL model with a 16 KiB simulation ROM
parameter (large enough for the same 9,236-byte image) and the production-size
512 KiB SRAM. It boots the actual image and compares:

- the self-test result;
- a full ML-KEM-768 decapsulation secret;
- a full ML-DSA-65 context-aware verification result;

against independently executed pinned clean code on the host.

For an ASIC release, archive the ELF, raw binary, hex image, compiler version,
submodule commits, source-tree hash, linker map, whole-chip regression log, and
the exact ROM macro initialization artifact together. Changing any compiler,
flag, source, memory timing, or dependency invalidates the existing firmware
verification evidence.
