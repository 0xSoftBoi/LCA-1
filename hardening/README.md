# SKY130 hardening evidence

LibreLane ([librelane/librelane](https://github.com/librelane/librelane),
OpenLane 2's maintained successor) hardening of the verified v0 arithmetic
slice (`lca_butterfly` + `lca_modmul`) on `sky130_fd_sc_hd`, per
`docs/IMPROVEMENT_PLAN.md` item 4. This converts area and timing for the
slice from "deferred" into measured signoff-level numbers.

## Claim boundary

- Results are **open-flow signoff estimates on the SKY130 PDK**, not
  fabricated-silicon measurements and not OpenFrame-integrated numbers.
  The shuttle-submission flow remains ChipFoundry's `cf harden`/precheck
  path; this project exists for measured QoR evidence and regression.
- The initial clock constraint is 10 ns (100 MHz), an unproven starting
  point in the range the improvement plan's ORFS/SHA-256 anchors suggest.
  Tightening it is evidence-driven: sweep only after a green run, and
  record the achieved worst slack alongside the constraint.

## Running

The `harden` workflow (`.github/workflows/harden.yml`, manual dispatch)
runs the pinned `ghcr.io/librelane/librelane:3.0.9` container, hardens the
macro, prints the headline metrics into the job summary, and uploads the
full run directory (reports, GDS, netlists, SDF, metrics.json) as an
artifact for 90 days.

Locally, with Docker available:

```bash
cd hardening/lca_butterfly
docker run --rm -v "$PWD/../..":/work -w /work/hardening/lca_butterfly \
  ghcr.io/librelane/librelane:3.0.9 \
  python3 -m librelane --pdk-root /work/.ciel-pdk config.json
```

Measured results are recorded per run in the workflow artifacts; do not
copy numbers into prose without the run link and commit hash.

## First measured run

Run [31885341711](https://github.com/0xSoftBoi/LCA-1/actions/runs/31885341711)
at commit `4a94379`, LibreLane 3.0.9 container, sky130A/sky130_fd_sc_hd,
CLOCK_PERIOD 10 ns, FP_CORE_UTIL 40. Full run directory (1,137 files
including GDS, netlists, STA and signoff reports) retained as artifact
`lca1-harden-4a94379…` (ID 9247177285, 90 days).

| metric | value |
|---|---|
| design__instance__count | 7,184 |
| design__instance__area | 36,697.7 µm² |
| design__die__area | 43,781.9 µm² |
| timing__setup__ws | **−3.237 ns** |
| timing__hold__ws | +0.104 ns |
| clock__skew__worst_setup | 0.271 ns |
| power__total | 1.269 mW |
| route__drc_errors / magic DRC / LVS errors | 0 / 0 / 0 |

Reading, per the claim-boundary rules:

- Physical signoff is clean (routing, DRC, LVS all zero) - the slice
  hardens on SKY130 with the open flow.
- The 10 ns (100 MHz) constraint is **not met**: worst setup slack is
  −3.237 ns, reported across corners including slow-slow 1.60 V/100 °C,
  i.e. a critical path of ≈13.2 ns in the worst corner (≈75 MHz
  equivalent there). The flow also warned "unable to repair all setup
  violations". Faster typical-corner behavior is visible in the archived
  STA reports but is not the number to quote.
- Power is the flow's estimate at its default activity assumptions, not a
  workload trace; the power-contract flow (improvement plan item 5) is the
  correct source for workload-shaped numbers.

## Constraint sweep — the v0 slice does not close

The hypothesis after the first run was that a relaxed constraint would
close timing. **It does not, and the trend runs the other way.** Three
runs, same design, same flow, same PDK, only `CLOCK_PERIOD` changed:

| Constraint | Run | Worst setup slack | Achieved path | Instances | Power |
|---|---|---|---|---|---|
| 10 ns | [31885341711](https://github.com/0xSoftBoi/LCA-1/actions/runs/31885341711) (`4a94379`) | −3.237 ns | **13.24 ns** | 7,184 | 1.269 mW |
| 13 ns | [31916826748](https://github.com/0xSoftBoi/LCA-1/actions/runs/31916826748) (`c6ff5c0`) | −1.190 ns | 14.19 ns | 7,361 | 0.969 mW |
| 14 ns | [31915959824](https://github.com/0xSoftBoi/LCA-1/actions/runs/31915959824) (`eeddc18`) | −0.959 ns | 14.96 ns | 7,445 | 0.896 mW |

Every run is physically clean: routing DRC, Magic DRC, and LVS all zero,
hold met (+0.104 to +0.107 ns), instance area identical at 36,697.7 µm².

Two readings, both worth stating plainly:

1. **The slice misses its target at every constraint tried (10–14 ns).**
   Slack improves as the target relaxes, but never reaches zero in this
   range, so no constraint in the sweep is a "closing" number.
2. **Relaxing the constraint makes the design slower, not faster.** The
   achieved path lengthens monotonically (13.24 → 14.19 → 14.96 ns) while
   power falls (1.269 → 0.969 → 0.896 mW) and cell count rises. The
   optimizer spends less effort on timing and more on power as the target
   loosens. The **best achieved critical path is at the tightest target**.

The honest v0 figure is therefore **≈13.24 ns worst-corner (≈75 MHz)
achieved but not met**, from the 10 ns run, at the highest power of the
three. `CLOCK_PERIOD` is left at 10 ns because that produced the best
timing result.

This is an architectural limit, not a constraint-tuning problem: the
24-bit conditional-subtract add/double chain is the critical path. The
pipelined K2-RED/Solinas reduction added in `rtl/lca_modmul_fast.sv`
(see `docs/FAST_REDUCTION.md`) targets exactly this path and is the
route to a faster part — but it has no hardening run of its own yet, so
no comparative PPA claim is made here.
