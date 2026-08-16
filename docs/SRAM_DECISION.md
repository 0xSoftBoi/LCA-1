<!-- SPDX-License-Identifier: Apache-2.0 -->

# Rev-A SRAM decision record

**Status: evidence gathered, decision not taken.** This record closes the
*geometry and licensing* half of the T1 `memory_area_timing` gate and states
exactly which decision criteria are still open. It declares no winner: the
criteria that would pick one are listed below, and four of nine are still
unmeasured.

Gate: `fabrication/rev_a_release.json` → `release_gates[T1]`, currently
`blocked` on `["T0 independent review", "commercial SRAM views/license"]`.
The second blocker is what this record attacks: a $2,500 macro licence stands
between the program and any memory number at all. If a free macro can carry
32 KiB inside the OpenFrame user area, T1 can proceed on measurements instead
of waiting on a purchase order.

Everything below is either **measured from a distributed LEF**, **quoted from a
published table**, **quoted from a vendor page**, or **computed** from those.
The tags are never mixed silently. Reproduce every number with:

```bash
python3 tools/sram_area.py            # human-readable, provenance-tagged
python3 tools/sram_area.py --json     # machine-readable
python3 tools/sram_area.py --check    # re-parses each quoted LEF SIZE line
```

## 1. What is actually obtainable

`docs/IMPROVEMENT_PLAN.md` §4 records the OpenRAM option as
"1/2/4/16 kB variants". Reading the trees on 2026-08-15 **that is not what is
distributed**, and the correction changes the arithmetic materially.

The three trees that distribute these macros —
[VLSIDA/sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros)
(upstream, `965df150c754fe2b3f93a0bd1f9883eb114279b2`), the efabless mirror,
and [fossi-foundation/sky130_sram_macros](https://github.com/fossi-foundation/sky130_sram_macros)
(the repository `open_pdks` clones into
`$PDK_ROOT/sky130A/libs.ref/sky130_sram_macros`) — all carry the **same four
macros**; upstream ships LEF+GDS+LIB+Verilog+SPICE for each, and the two
mirrors were checked to carry an identical LEF set:

| Macro | LEF `SIZE` line (verbatim) | Area | Capacity |
|---|---|---|---|
| `sky130_sram_1kbyte_1rw1r_32x256_8` | `SIZE 479.78 BY 397.5 ;` | 0.1907 mm² | 1 KiB |
| `sky130_sram_1kbyte_1rw1r_8x1024_8` | `SIZE 455.3 BY 446.46 ;` | 0.2033 mm² | 1 KiB |
| `sky130_sram_2kbyte_1rw1r_32x512_8` | `SIZE 683.1 BY 416.54 ;` | 0.2845 mm² | 2 KiB |
| `sram_1rw1r_32_256_8_sky130` (legacy) | `SIZE 376.48 BY 446.235 ;` | 0.1680 mm² | 1 KiB |

The 4 kB and 16 kB directories contain **only a `.log` file**. Both logs are
truncated mid-run — the 16 kB log's last line is
`Still running .../run_lvs.sh (9851 seconds)`, the 4 kB (`128x256_128`) log
stops inside supply routing — and neither directory has a LEF, GDS or LIB.
`configs/` holds Python configs for 4 kB, 8 kB and 16 kB variants, and the
repository history contains a commit literally titled *"Comment out 8kb and
16kb"*. **So: 4 kB, 8 kB and 16 kB OpenRAM macros are generatable, not
downloadable.** Using them means running OpenRAM (a ~4 hour job per macro,
per the 1 kB log's `** End: 4907.9 seconds`) and then owning the DRC/LVS
result yourself.

The ISCAS 2023 paper's Table I quotes dimensions for the taped-out MPW2
configurations. For the three macros that also ship views, Table I reproduces
the LEF `SIZE` numbers exactly (455.3×446.5, 479.8×397.5, 683.1×416.5), which
is why the two rows below are treated as trustworthy geometry even though no
view exists to measure:

| Macro (no view distributed) | ISCAS 2023 Table I | Area | Capacity |
|---|---|---|---|
| `sky130_sram_4kbyte_1rw1r_32x1024_8` | 693.9 × 668.8 µm | 0.4641 mm² | 4 KiB |
| `sky130_sram_8kbyte_1rw1r_32x2048_8` | 1093.8 × 720.5 µm | 0.7881 mm² | 8 KiB |

A second free generator, **SRAM22**
([rahulk29/sram22_sky130_macros](https://github.com/rahulk29/sram22_sky130_macros),
`75cbe961e18ee00d5a6c73fa455505f0bcdf4c05`, BSD-3-Clause), distributes 22
placeable macros including 32-bit-word arrays larger than anything OpenRAM
ships:

| Macro | LEF `SIZE` line (verbatim) | Area | Capacity | Ports |
|---|---|---|---|---|
| `sram22_512x32m4w8` | `SIZE 443.280 BY 448.720 ;` | 0.1989 mm² | 2 KiB | 1RW |
| `sram22_1024x32m8w8` | `SIZE 764.240 BY 460.280 ;` | 0.3518 mm² | 4 KiB | 1RW |
| `sram22_2048x32m8w8` | `SIZE 674.480 BY 781.920 ;` | 0.5274 mm² | 8 KiB | 1RW |

Its README lists `sram22_4096x32m8w8` (16 KiB) as taped out, but **no 4096-word
macro is in the repository** — the same "listed but not shipped" pattern as
OpenRAM's large variants.

## 2. Area: 32 KiB and 64 KiB banks

Computed by `tools/sram_area.py` as instances × macro outline, at a 32-bit data
bus. These totals are **macro outlines only** — no halos, routing channels,
wrapper logic, or PDN. The `[VENDOR]` reference is ChipFoundry's published
figure, not a measurement.

| Path | 32 KiB | 64 KiB | vs CF | Licence | Views |
|---|---|---|---|---|---|
| `CF_SRAM_8192x32` `[VENDOR]` | 1 × = **1.340 mm²** | 2 × = 2.680 mm² | 1.00× | $2,500/project | after purchase |
| `sram22_2048x32m8w8` `[LEF]` | 4 × = **2.110 mm²** | 8 × = 4.219 mm² | 1.57× | BSD-3-Clause | yes |
| `sram22_1024x32m8w8` `[LEF]` | 8 × = 2.814 mm² | 16 × = 5.628 mm² | 2.10× | BSD-3-Clause | yes |
| `sky130_sram_8kbyte…` `[PAPER]` | 4 × = 3.152 mm² | 8 × = 6.305 mm² | 2.35× | Apache-2.0 | **no** |
| `sram22_512x32m4w8` `[LEF]` | 16 × = 3.183 mm² | 32 × = 6.365 mm² | 2.38× | BSD-3-Clause | yes |
| `sky130_sram_4kbyte…` `[PAPER]` | 8 × = 3.713 mm² | 16 × = 7.425 mm² | 2.77× | Apache-2.0 | **no** |
| `sky130_sram_2kbyte_1rw1r_32x512_8` `[LEF]` | 16 × = **4.553 mm²** | 32 × = 9.105 mm² | 3.40× | Apache-2.0 | yes |
| `sram_1rw1r_32_256_8_sky130` `[LEF]` | 32 × = 5.376 mm² | 64 × = 10.752 mm² | 4.01× | Apache-2.0 | yes |
| `sky130_sram_1kbyte_1rw1r_32x256_8` `[LEF]` | 32 × = 6.103 mm² | 64 × = 12.206 mm² | 4.55× | Apache-2.0 | yes |

Against the 15.0 mm² OpenFrame user area
(`fabrication/rev_a_release.json` → `route.shell.user_area_mm2`):

- **32 KiB, best downloadable Apache-2.0 path** (16 × 2 kB OpenRAM):
  4.553 mm², **30.4 %** of the user area, +3.213 mm² versus the commercial
  macro.
- **32 KiB, best downloadable free path overall** (4 × 8 KiB SRAM22, BSD-3):
  2.110 mm², **14.1 %** of the user area, +0.770 mm² versus commercial.
- **64 KiB on the OpenRAM path**: 9.105 mm², **60.7 %** of the user area — that
  leaves 5.9 mm² for the entire accelerator, pads and PDN. On the evidence
  here the 64 KiB experiment stays an experiment.

An **ESTIMATE** including channels (not a placement result), from
`python3 tools/sram_area.py --channel-x 40 --channel-y 120 --margin 100`: a
4 × 4 array of the 2 kB macro occupies 3052.4 × 2226.2 µm = **6.795 mm²** of
bounding box. That envelope, not the 4.553 mm² of macro outlines, is what the
floorplan in `hardening/lca_sram_fit/config.json` has to hold, and it is the
number that decides whether 32 KiB of OpenRAM fits the user area **with** the
accelerator beside it.

## 3. Cost and licence auditability

| | OpenRAM `sky130_sram_macros` | SRAM22 | ChipFoundry commercial |
|---|---|---|---|
| Price | $0 | $0 | $2,500 per project (unlimited instances) |
| Licence | Apache-2.0 | BSD-3-Clause | commercial; terms not published |
| Inbound-compatible | yes (matches `NOTICE` policy, and §"Donor-code license compatibility" already lists it) | yes, with attribution | requires review of unpublished terms |
| Views inspectable pre-commitment | yes — LEF/GDS/LIB/Verilog/SPICE in git, per-commit | yes | **no** — delivered through IPM after purchase |
| Redistributable in this repository | yes | yes | almost certainly not |
| Reproducible from source | yes (OpenRAM + config) | yes (SRAM22 + config) | no |

The auditability gap is the sharpest difference and it is not about money. For
the commercial macro, **no dimensions, aspect ratio, port list, timing model,
port count or licence text is public**: the product page states 32 KB, 1.34 mm²,
"Wishbone Bus", $2,500. Two ChipFoundry pages also disagree about the smallest
macro — the catalog says `SRAM_1024x32` is 0.165 mm², while the macro page gives
387.870 µm × 303.315 µm = 0.1176 mm². Neither figure is checkable without
buying. Every claim this program would make about a commercial-macro Rev-A
would rest on a vendor sentence, which is precisely what the repository's
evidence rules forbid.

The free path inverts that: every number in §1 was read out of a file in a
pinned commit, and `tools/sram_area.py --check` re-parses the quoted `SIZE`
lines on every CI run.

## 4. Silicon lineage

The OpenRAM SKY130 silicon evidence is
[Cirimelli-Low, Khan, Crow, Lonkar, Onal, Zonenberg, Guthaus, *SRAM Design with
OpenRAM in SkyWater 130nm*, ISCAS 2023](https://ieeexplore.ieee.org/document/10181379/)
(DOI 10.1109/ISCAS46773.2023.10181379; open-access copy at
[escholarship.org/uc/item/9dc0v8g3](https://escholarship.org/uc/item/9dc0v8g3)).
Read it per macro, because it does not cover the family uniformly.

**What it covers.** The OR1 test chip contains exactly one memory: "a single,
byte-writable 32-bit 1-kilobyte dual-port SRAM with 1RW port and 1R port" —
i.e. `sky130_sram_1kbyte_1rw1r_32x256_8`. Five dies were measured across three
thermal corners (targets ≈0 °C, ≈23 °C, ≈85 °C) with a bonded-out subset of
data bits. Reported: "There were no errors above 1.7 V at frequencies below
34 MHz with both ports simultaneously reading the same addresses"; with one
read port active at 25 MHz the supply could drop to 1.54 V; retention errors
first appeared at 440 mV cold and 410 mV hot. It also records a test-setup
finding worth carrying into board design: "Very large (over 10 ns in some
cases) read capture delays were needed, due to excessive unbuffered routing
delay between the OpenRAM macro's outputs and the I/O pad cells."

**What it does not cover.** Table I lists ten memory configurations taped out
on the **MPW2** chip — including the 2 kB, 4 kB and 8 kB 1RW1R macros — but the
paper reports **no MPW2 measurements at all**; it closes by saying the authors
"look forward to verifying the MPW2 test chip." So:

- `sky130_sram_1kbyte_1rw1r_32x256_8` — measured in silicon. ✅
- `sky130_sram_2kbyte_1rw1r_32x512_8` (the macro this decision would use) —
  **taped out, not measured in any published result.** ⚠️
- 4 kB / 8 kB / 16 kB — taped out (4 kB, 8 kB) or never built (16 kB), no
  measurements, no distributed views. ⚠️
- No yield, no per-corner characterization, no ageing, no data-retention
  guarantee at scale, and nothing about 16 macros operating simultaneously.

The transferable claim is therefore narrow and should be stated exactly that
way: **the OpenRAM SKY130 bitcell array, periphery and generator flow have
produced working silicon in this process, for one 1 KiB configuration, at
≤34 MHz.** It is not a qualification of the 2 kB macro.

SRAM22's lineage is weaker still and is README-grade: the macros "have been
taped out via Cadence's shuttle program and behaved correctly in silicon
measurements when tested at VDD=1.8V and at a clock frequency of 25 MHz", with
no paper, no per-die data, and an explicit "use all macros provided here at
your own risk". ChipFoundry publishes no silicon statement for its macro at
all.

## 5. Integration friction

Measured or read from the artefacts, not estimated:

1. **Macro count.** 32 KiB needs 16 OpenRAM 2 kB macros versus 1 commercial
   macro. Sixteen macros mean sixteen PDN hookups, sixteen halo regions, a
   16-way 32-bit read multiplexer, and a floorplan that dominates the block.
2. **Timing views are single-corner and analytical.** The shipped
   `..._TT_1p8V_25C.lib` is the only corner, and the generation log states
   `Characterization is disabled (using analytical delay models)
   (analytical_delay=False to simulate)`. Its clk→dout values are 0.383–0.529 ns
   and its dynamic power figure (13.8 mW) comes from
   `characterizer.elmore/analytical_power`. **There is no SS or FF SRAM lib**,
   so multi-corner STA of a bank cannot be signed off from what is
   distributed — the very corner (slow-slow 1.60 V/100 °C) that dominated the
   `lca_butterfly` run in `hardening/README.md`. The legacy
   `sram_1rw1r_32_256_8_sky130` is the only macro shipping FF/SS/1.7 V/1.9 V/
   0 °C/100 °C libs.
3. **DRC status of the shipped GDS is unverified.** The committed logs record
   `DRC Errors sky130_sram_1kbyte_1rw1r_32x256_8 10` and
   `DRC Errors sky130_sram_2kbyte_1rw1r_32x512_8 32`, but those logs date from
   2021-06-14 while the GDS files were replaced on 2024-07-12 by the merge
   titled *"sky130_drc_update"*, with no refreshed log or report committed.
   The errors may well be fixed; the repository does not show it. **This must
   be re-run locally before any tapeout decision** — it is the single largest
   unquantified risk on the free path, and `cf precheck` will find it either
   way.
4. **Pin and power topology.** The 2 kB macro puts all signal pins on met4 at
   the top and bottom edges, with `vccd1`/`vssd1` rails on the left and right
   edges — so rows need vertical routing channels, and the array cannot be
   packed edge to edge. SRAM22 names its supplies `vdd`/`vss` instead, which
   changes the PDN hookup strings.
5. **Port structure.** OpenRAM 1RW1R matches the Rev-A pattern (host stream
   writes, coefficient reads) directly. SRAM22's 32-bit macros are **single
   port**, so its 2.1 mm² advantage would be paid back in arbitration logic and
   lost concurrency — a real architectural cost, not just area.
6. **The commercial macro's friction is unknown by construction.** Its
   interface is described only as "Wishbone Bus"; whether it is single- or
   dual-port, what its cycle behaviour is, and whether it needs a bridge from
   the LCA-LINK-16 stream path cannot be determined before purchase.

## 6. Decision criteria

| # | Criterion | Threshold | Status |
|---|---|---|---|
| 1 | 32 KiB fits the OpenFrame user area with room for the accelerator | bank ≤ ~40 % of 15.0 mm² | **satisfied** for OpenRAM 2 kB (30.4 % of outlines; 6.795 mm² / 45 % as an envelope estimate) and for SRAM22 (14.1 %) |
| 2 | Views obtainable without a commercial agreement | LEF+GDS+LIB in a pinned commit | **satisfied** (OpenRAM, SRAM22); not satisfied for CF |
| 3 | Licence compatible with inbound Apache-2.0 and auditable pre-commitment | text readable today | **satisfied** (Apache-2.0 / BSD-3-Clause); **unsatisfied** for CF (terms unpublished) |
| 4 | Cost inside the Rev-A commercial snapshot | ≤ $2,500 add-on | **satisfied** by both free paths at $0 |
| 5 | Silicon lineage in SKY130 | published measurement of the exact macro | **not satisfied** — measured for the 1 KiB macro only; the 2 kB macro is taped out but unmeasured |
| 6 | Multi-corner timing closure of the bank at the target clock | signed-off STA, all corners | **not measured** — no SS/FF SRAM libs exist to close against |
| 7 | DRC/LVS clean in context | 0 errors on the hardened wrapper | **not measured**; upstream macro DRC status also unverified (§5.3) |
| 8 | IR drop and EM on a 16-macro array | within PDK limits | **not measured** |
| 9 | Zeroize/scrub semantics implementable at full capacity | scrub of every bank before ready | **not designed** — `lca_sram_fit` is a fit probe with no zeroize logic |

Four of nine criteria are satisfied on evidence; one is answered negatively for
the macro that would actually be used (silicon lineage); four require a
hardening run that has not happened. **No selection is made here.** What has
changed is the shape of the remaining question: it is no longer "can we afford
views?" but "does a 16-macro free bank close timing, DRC/LVS and IR/EM?" — a
question this repository can answer with its own tooling, at no cost, before
anyone signs a purchase order.

## 7. The hardening probe: `hardening/lca_sram_fit`

`hardening/lca_sram_fit/` holds a LibreLane project that hardens
`lca_sram_fit` — 8192 words × 32 bits assembled from 16 instances of
`sky130_sram_2kbyte_1rw1r_32x512_8`, with both macro ports wired (port 0
read/write, port 1 read-only), a registered bank-select read multiplexer, and
nothing else. It is deliberately not Rev-A memory RTL: there is no CSR
interface, no zeroize sequencer, and no tamper path, all of which
`fabrication/rev_a_release.json` requires of the real block.

Files:

| File | Role |
|---|---|
| `lca_sram_fit.sv` | the 32 KiB wrapper (instance array, so flattened names are `u_bank[0] … u_bank[15]`) |
| `sky130_sram_2kbyte_1rw1r_32x512_8.vh` | black-box declaration matching the upstream behavioural model's port list |
| `config.json` | canonical config: `MACROS` with `gds`/`lef`/`vh`/`lib` and all 16 instance locations |
| `config_extra_lefs.json` | equivalent wiring through `EXTRA_LEFS`/`EXTRA_GDS_FILES`/`EXTRA_LIBS`/`EXTRA_VERILOG_MODELS`, for flows that prefer flat view lists. **Use one or the other, never both** — loading the same LEF twice fails. It carries no instance locations, so the macro placer chooses them |

The floorplan is absolute and derived from the LEF geometry, not guessed:
a 4 × 4 array on a 723.1 µm horizontal pitch (683.1 + 40 µm channel) and a
536.54 µm vertical pitch (416.54 + 120 µm channel, since all signal pins are on
the top and bottom edges), origin (100, 100), inside a
`DIE_AREA` of 3060 × 2230 µm. Macro views are referenced through
`pdk_dir::libs.ref/sky130_sram_macros/…`, which is where `open_pdks` installs
them; if a PDK build lacks that library, clone the upstream repository and
switch those four paths to `dir::`.

Running it (Docker, same pinned container as `hardening/lca_butterfly`):

```bash
cd hardening/lca_sram_fit
docker run --rm -v "$PWD/../..":/work -w /work/hardening/lca_sram_fit \
  ghcr.io/librelane/librelane:3.0.9 \
  python3 -m librelane --pdk-root /work/.ciel-pdk config.json
```

It has **not been run** — no LibreLane container, PDK or Docker daemon exists
in the environment where this record was written, so no metric here comes from
it. What has been verified locally is that the RTL elaborates and that the
instance names match the config: `iverilog -g2012` elaborates `lca_sram_fit`
cleanly, and Yosys flattens it to exactly 16 `sky130_sram_2kbyte_1rw1r_32x512_8`
cells named `u_bank[0] … u_bank[15]`, matching the `MACROS` instance keys.

A green run would produce, in one shot, the four missing criteria from §6:

- **criterion 6** — worst setup/hold slack for the bank at 14 ns (71 MHz), the
  same constraint `hardening/lca_butterfly` now carries, plus whatever the
  read-multiplexer path costs. Note that the only silicon evidence for any
  OpenRAM SKY130 macro tops out at 34 MHz (§4), so a passing STA result at
  71 MHz would be an open-flow estimate that the silicon record does not yet
  support;
- **criterion 7** — `route__drc_errors`, Magic DRC and netgen LVS on the array
  in context, which also exercises the unverified upstream GDS from §5.3;
- **criterion 8** — the PDN over 16 macros, and whether `PDN_MACRO_CONNECTIONS`
  reaches every `vccd1`/`vssd1` ring;
- and the real answer to **criterion 1**: `design__die__area` versus the
  6.795 mm² envelope estimate.

Until it runs, treat §2 as geometry and nothing more.

## 8. Still missing

- No hardening run: no measured area, no achieved clock, no DRC/LVS/antenna
  result, no IR/EM, no power (**UNVERIFIED**).
- No SS/FF liberty views for any current OpenRAM macro, so multi-corner
  signoff of an SRAM bank is not possible from distributed files
  (**UNVERIFIED**, and not fixable by us without SPICE characterization).
- Upstream macro DRC status after the 2024 GDS refresh (**UNVERIFIED**).
- No published silicon measurement of `sky130_sram_2kbyte_1rw1r_32x512_8`
  (**UNVERIFIED — and unlikely to become verified**; treat as residual risk).
- SRAM22 silicon claim is a README assertion with no artefact
  (**UNVERIFIED**).
- Commercial macro: area, dimensions, ports, timing and licence text all rest
  on two vendor pages that disagree with each other (**UNVERIFIED, and
  unverifiable pre-purchase**).
- Zeroize/scrub cost — cycles, area and the ready-blocking behaviour required
  by `rev_a_release.json` `memory.zeroize` — is not modelled in the fit probe.
- Whether a 3.06 × 2.23 mm block fits the OpenFrame user-area *outline* (as
  opposed to its 15.0 mm² area) is unchecked; the aspect ratio of that area is
  not pinned anywhere in this repository (**UNVERIFIED**).
- 64 KiB: at 9.105 mm² of macro outline on the OpenRAM path it is not
  obviously placeable at all, and the promotion rule in
  `rev_a_release.json` (`memory.experiment.promotion_rule`) is untested.

## 9. Sources

| Source | Retrieved | Used for |
|---|---|---|
| [VLSIDA/sky130_sram_macros](https://github.com/VLSIDA/sky130_sram_macros) @ `965df150c754fe2b3f93a0bd1f9883eb114279b2` | 2026-08-15 | LEF `SIZE` lines, generation logs, liberty views, file history |
| [fossi-foundation/sky130_sram_macros](https://github.com/fossi-foundation/sky130_sram_macros) @ `5ad1c96053ee8223fe7e956e314646adfce605dd` | 2026-08-15 | confirming the `open_pdks` install set is the same four macros |
| [efabless/sky130_sram_macros](https://github.com/efabless/sky130_sram_macros) @ `ebfbf5775c8cd433ad38a4d825e46c2275231511` | 2026-08-15 | same, third mirror |
| [RTimothyEdwards/open_pdks](https://github.com/RTimothyEdwards/open_pdks) `sky130/Makefile.in` | 2026-08-15 | which SRAM library the PDK installs, and from where |
| [rahulk29/sram22_sky130_macros](https://github.com/rahulk29/sram22_sky130_macros) @ `75cbe961e18ee00d5a6c73fa455505f0bcdf4c05` | 2026-08-15 | SRAM22 LEF `SIZE` lines, pin list, licence, tapeout claim |
| [Cirimelli-Low et al., ISCAS 2023](https://ieeexplore.ieee.org/document/10181379/) ([open access](https://escholarship.org/uc/item/9dc0v8g3)) | 2026-08-15 | silicon lineage, Table I geometry, measured OR1 results |
| [ChipFoundry commercial SRAM catalog](https://chipfoundry.io/commercial-sram) | 2026-08-15 | `SRAM_1024x32`/`4096x32`/`8192x32` areas, $2,500 per project |
| [ChipFoundry SRAM macro page](https://chipfoundry.io/commercial-sram-macro) | 2026-08-15 | `SRAM_1024x32` dimensions (and the disagreement with the catalog) |
| [LibreLane 3.0.9 `using_macros`](https://github.com/librelane/librelane/blob/3.0.9/docs/source/usage/using_macros.md) and `librelane/config/flow.py` | 2026-08-16 | exact `MACROS`, `EXTRA_LEFS`, `EXTRA_GDS_FILES`, `PDN_MACRO_CONNECTIONS`, `DIE_AREA` semantics |
