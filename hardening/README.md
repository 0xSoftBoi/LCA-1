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

Next constraint step: either close timing at a relaxed constraint
(≈14-15 ns, ≈66-70 MHz worst-corner) and record it as the honest v0
number, or pursue the improvement plan's pipelined-reduction upgrade
(item 7), which targets exactly this critical path - the 24-bit
conditional-subtract add/double chain.
