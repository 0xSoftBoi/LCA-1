<!-- SPDX-License-Identifier: Apache-2.0 -->

# 32 KiB SRAM fit probe

LibreLane project that hardens `lca_sram_fit`: 8192 words × 32 bits assembled
from 16 instances of the Apache-2.0 OpenRAM macro
`sky130_sram_2kbyte_1rw1r_32x512_8`. It exists to turn the Rev-A memory
question from a vendor quotation into a measurement, per
[`docs/SRAM_DECISION.md`](../../docs/SRAM_DECISION.md) and
`docs/IMPROVEMENT_PLAN.md` item 6.

## Claim boundary

- **This has not been run.** No area, clock, DRC, LVS, IR or power number in
  this repository comes from it. What is verified locally is only that the RTL
  elaborates (`iverilog -g2012`) and that Yosys flattens it to exactly 16 macro
  cells named `u_bank[0] … u_bank[15]`, matching the `MACROS` instance keys in
  `config.json`.
- `lca_sram_fit.sv` is a **fit probe, not Rev-A memory RTL**: no CSR interface,
  no zeroize sequencer, no tamper path, no error reporting. The Rev-A block
  needs all of those (`fabrication/rev_a_release.json` → `memory.zeroize`).
- The macro's only distributed liberty view is TT 1.8 V 25 °C with
  *analytical*, non-SPICE delays, so any STA result from this project is
  single-corner for the memories even when the standard cells are
  multi-corner. Read `docs/SRAM_DECISION.md` §5 before quoting timing.
- The 14 ns (71 MHz) constraint mirrors `hardening/lca_butterfly`. The only
  published silicon measurement of any OpenRAM SKY130 macro tops out at
  34 MHz, on a different (1 KiB) macro. The constraint is a starting point,
  not a claim.

## Files

| File | Role |
|---|---|
| `lca_sram_fit.sv` | 32 KiB wrapper; instance array so flattened names are `u_bank[i]` |
| `sky130_sram_2kbyte_1rw1r_32x512_8.vh` | black-box declaration mirroring the upstream behavioural model's ports |
| `config.json` | canonical config: `MACROS` with `gds`/`lef`/`vh`/`lib` plus all 16 placements |
| `config_extra_lefs.json` | same design wired through `EXTRA_LEFS`/`EXTRA_GDS_FILES`/`EXTRA_LIBS`/`EXTRA_VERILOG_MODELS`; **mutually exclusive** with `config.json` — loading the same LEF twice fails. It carries no instance locations, so macro placement is left to the tool |

Macro views resolve through `pdk_dir::libs.ref/sky130_sram_macros/…`, where
`open_pdks` installs them. If a PDK build lacks that library, clone
[VLSIDA/sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros) and
change those paths to `dir::`.

## Running

```bash
cd hardening/lca_sram_fit
docker run --rm -v "$PWD/../..":/work -w /work/hardening/lca_sram_fit \
  ghcr.io/librelane/librelane:3.0.9 \
  python3 -m librelane --pdk-root /work/.ciel-pdk config.json
```

Record results the same way `hardening/README.md` does: run link, commit hash,
headline `metrics.json` values, and the reading of them — never numbers copied
into prose without the run they came from.

## Floorplan

Derived from the LEF outline (`SIZE 683.1 BY 416.54 ;`), not guessed: a 4 × 4
array, 723.1 µm horizontal pitch (683.1 + 40 µm channel), 536.54 µm vertical
pitch (416.54 + 120 µm channel, because every signal pin sits on the top and
bottom edges), origin (100, 100), inside a 3060 × 2230 µm `DIE_AREA`.
`tests/test_sram_area.py` checks those placements against the LEF-measured
geometry, so the config and `tools/sram_area.py` cannot drift apart.
