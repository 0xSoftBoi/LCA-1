# LCA-1 S0 Rev-A fabrication and package release

This is the working manufacturing release for `LCA1-S0-REV-A`. It converts the
program goal into a foundry-facing artifact set while keeping every unearned
claim and vendor-owned detail visibly open.

## Current disposition

| Item | Selected working value | Release state |
| --- | --- | --- |
| Service | ChipFoundry chipIgnite | Published route; no contract or reservation |
| Shuttle | CI2612 | Planning target; commitment 2026-10-08, tapeout 2026-12-07 |
| Process | SKY130 | Vendor-published; exact PDK release not yet pinned |
| Shell | Standard OpenFrame, pinned template commit `ca732a...` | Pinned for smoke test; vendor acceptance open |
| User area | 15 mm2 | Vendor-published shell limit, not achieved design area |
| I/O | 44 configurable GPIO | Assigned in the package manifest |
| Baseline memory | One `CF_SRAM_8192x32` (32 KiB) | Commercial views/license open |
| Memory experiment | Two `CF_SRAM_8192x32` (64 KiB) | Must beat all T1 gates before promotion |
| Package | 64-pin QFN, 9 mm x 9 mm, 0.5 mm pitch, exposed VSS paddle | Datasheet-derived, vendor confirmation required |
| Delivery snapshot | 100 QFN, ten M.2 assemblies, one evaluation board | Published base offer; not contracted |

ChipFoundry's current public flow requires a GDSII for the OpenFrame user area.
The vendor integrates that GDSII into its golden shell. Therefore LCA-1 does
not own the final die padframe, wire-bond coordinates, or assembly drawing. It
does own the exact user-wrapper contract, logical GPIO allocation, package pin
requirements, board defaults, functional test content, and release evidence.

## Controlled artifacts

| Artifact | Purpose |
| --- | --- |
| [`rev_a_release.json`](../fabrication/rev_a_release.json) | Route, boundary, RTL cut-list, memory, link, gates, and source evidence |
| [`rev_a_release.schema.json`](../fabrication/rev_a_release.schema.json) | Structural contract for the release manifest |
| [`rev_a_package.json`](../fabrication/rev_a_package.json) | QFN pinout, logical GPIOs, pad modes, assembly constraints, ATE plan, and blockers |
| [`rev_a_package.schema.json`](../fabrication/rev_a_package.schema.json) | Structural contract for the package manifest |
| [`rev_a_qfn_pinout.csv`](../fabrication/generated/rev_a_qfn_pinout.csv) | Generated schematic/fixture pin table |
| [`rev_a_gpio_map.csv`](../fabrication/generated/rev_a_gpio_map.csv) | Generated wrapper/pad-control review table |
| [`rev_a_ate_plan.csv`](../fabrication/generated/rev_a_ate_plan.csv) | Generated incoming, functional, and characterization test matrix |
| [`REV_A_INTEGRATION.md`](REV_A_INTEGRATION.md) | Human-reviewable architecture and cycle contract |

`python3 tools/gen_fabrication_artifacts.py --check` prevents hand-edited CSVs.
`python3 tools/validate_fabrication.py` cross-checks the two manifests, the live
RTL tree, the 64 package pins plus exposed paddle, all 44 GPIOs, pad safety,
memory limits, schedule status, source pins, and release gates.

## Package pin source and erratum

The pinned OpenFrame datasheet Figure 2 provides the non-specific 64-QFN pinout.
Its later text table contains a conflict: pin 31 is correctly listed as
`gpio[0]` but is also included in the `vssa1` row. Figure 2 clearly maps
`vssa1` to pins 38 and 52. This release uses Figure 2:

- QFN pin 31 = `gpio[0]`;
- QFN pin 38 = `vssa1`;
- QFN pin 52 = `vssa1`.

That decision is provisional. ChipFoundry must confirm it in writing or provide
a superseding controlled drawing before package freeze. The complete 1-64 and
exposed-paddle map is generated in `rev_a_qfn_pinout.csv`.

## Logical package interface

Rev-A spends the 44 GPIOs on a single 16-bit synchronous link:

- 16 bidirectional data pins;
- eight address/channel pins;
- request valid/ready/write/last;
- response valid/ready/last;
- IRQ, tamper, zeroize, busy, fault, zeroize-busy, and self-test-fail;
- one external functional clock;
- five electrically disabled reserves.

The fixed OpenFrame `resetb` package pin is the master reset. There is no bonded
debug-unlock or factory-test-mode signal. Functional production test uses the
same bounded host link as the appliance. This reduces hidden state and test
surface, but it does not replace scan-coverage analysis or justify a production
quality/yield claim.

The generated GPIO map includes the package pin and SKY130 pad controls for each
signal. Inputs use 3.3 V CMOS thresholds. Ordinary outputs are slow-edge,
push-pull by default. Data pads drive only while `rsp_valid` is asserted. Spares
are high impedance with input buffers disabled.

## Power, reset, and board contract

The working rail map includes the OpenFrame `vccd1` 1.8 V user core supply,
`vddio` 3.3 V pad/ESD supply, all published analog/digital supply pins, grounds,
and the VSS exposed paddle. No unused-domain power pin is silently left open:
its final tie is a vendor question.

The board must:

1. establish grounds and current-limited rails under reset;
2. hold `resetb` low until all required rails, host I/O states, and `host_clk`
   are valid;
3. hold `tamper_n` low when the host/security controller is absent, so a broken
   connection fails into the tamper state;
4. release the bidirectional bus before an accepted read can return;
5. expose rail current measurement, reset, clock, tamper, and all link signals
   to the characterization fixture;
6. record board revision and unit traceability with every measurement.

Decoupling values, rail sequencing intervals, exposed-paddle via geometry,
package current limits, IBIS/parasitic models, connector assignment, and thermal
limits remain open until the current package and evaluation-board data arrive.
Inventing those values would be less useful than maintaining explicit blockers.

## Assembly release package

The vendor/assembler handoff is incomplete until it contains controlled
versions of:

- 64-QFN mechanical and recommended-land-pattern drawings;
- final package pinout, die-pad/bond map, wire rules, and exposed-paddle detail;
- substrate/leadframe, mold compound, terminal finish, package marking, and
  serialization instructions;
- MSL, floor life, bake, storage, reflow, X-ray/AOI, and ESD handling limits;
- wafer-map/die traceability and known-good-die disposition;
- board fabrication files, BOM with lifecycle status, assembly drawings,
  programming/test instructions, and golden-unit criteria;
- socket and fixture drawings, contact-life plan, calibration, guardband, and
  correlation method;
- approved deviations/waivers and named acceptance authorities.

ChipFoundry supplies or controls several of these for its standard package.
LCA-1 records their revisions and hashes; it does not recreate vendor drawings
from an old PDF.

## Test flow

The machine-readable plan defines eleven stable test IDs:

1. package continuity/shorts;
2. current-limited power sequencing;
3. reset, startup scrub, identity, and ABI read;
4. full-address destructive SRAM March test;
5. Keccak-f[1600] known-answer test;
6. ML-KEM NTT/INTT known-answer test;
7. ML-DSA NTT/INTT known-answer test;
8. host zeroize and tamper zeroize with complete state readback;
9. request/response backpressure and bus-contention test;
10. voltage/frequency/temperature characterization;
11. synchronized per-mode power characterization.

Each final vector must be traceable from independent oracle output to exact
halfword transactions and expected pin-level timing. Passing one room-temperature
unit is bring-up evidence, not qualification. Limits and guardbands require a
sample plan across units, corners, and at least the lots available from the
prototype run.

## Fabrication release sequence

1. Independent T0 review freezes the accelerator boundary and LCA-LINK-16.
2. Acquire the commercial SRAM views/terms and run matched 32/64 KiB area,
   timing, power, and zeroize experiments.
3. Port only the selected Rev-A RTL into the pinned OpenFrame template; implement
   explicit pad controls and `vccd1_connection`/`vssd1_connection`.
4. Run RTL and GL full-chip simulations through package-level transactions.
5. Harden each macro, then the wrapper; close STA, congestion, antenna, DRC,
   LVS, IR/EM, and power-integrity gates with zero unowned violations.
6. Run local `cf precheck`; archive tool/PDK/container pins, reports, GDSII,
   hashes, waivers, and review identities as one immutable release candidate.
7. Resolve the package erratum and every freeze blocker against controlled
   vendor documents; release board, fixture, and ATE packages.
8. Obtain explicit commercial, legal, export, reservation/payment, and final
   mask-release authorization.
9. Submit only the approved release hash. Record vendor acceptance and any
   post-submission transformation.

No repository commit can perform steps 2, 7, 8, or 9 by itself. Those are real
external gates, and the manifests are intentionally structured so they cannot
be mistaken for completed fabrication.
