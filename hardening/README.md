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
