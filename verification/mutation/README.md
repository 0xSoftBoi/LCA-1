# Mutation coverage of the generated corpus

This MCY ([YosysHQ/mcy](https://github.com/YosysHQ/mcy)) project measures
whether the 280-case generated differential corpus would **detect** an
injected netlist-level bug in `lca_modmul` + `lca_butterfly`. Corpus size and
formal scope do not answer that question; mutation testing does.

## What it does

1. Yosys elaborates and flattens the two modules and generates `size`
   random mutations (connection swaps, constant drives, operator changes)
   in the netlist.
2. For each mutation, the full 280-case corpus replays under Icarus Verilog
   against the mutated netlist (`test_sim.sh`).
3. A mutant the corpus fails is tagged `COVERED` (killed); a mutant that
   survives every case is `UNCOVERED`. The report prints the kill ratio.

## Claim boundary

- This layer is a **coverage signal, not an E1 gate**. It runs on a host
  Yosys + Icarus toolchain whose versions are recorded in the run log, not
  the lockfile-pinned Yosys 0.68 used by `make verify`.
- No formal-equivalence filter is configured yet, so mutations that are
  functionally equivalent to the original design (undetectable by any
  possible test) still count against coverage. The reported number is a
  **lower bound** on real corpus strength. Adding an sby-based `test_eq`
  stage is the planned refinement (`docs/IMPROVEMENT_PLAN.md`).
- A surviving non-equivalent mutant is a corpus gap: file a defect issue
  citing the mutation ID and extend the generator - never hand-patch the
  corpus.

## Running locally

```bash
# prerequisites: yosys and iverilog on PATH, python3 with click,
# and a clone of YosysHQ/mcy (commit 5a2cad0 or later)
cd verification/mutation
python3 /path/to/mcy/mcy.py init
python3 /path/to/mcy/mcy.py run -j"$(nproc)"
python3 /path/to/mcy/mcy.py status
```

The `database/` and `tasks/` directories are generated state and are not
committed. CI runs this project nightly (`.github/workflows/mutation.yml`)
and uploads the report as an artifact.

## First measured campaign

Measured 2026-08-15 in the development container (Yosys 0.33, Icarus
Verilog 12.0, MCY commit `5a2cad0`, 200 mutations of the synthesized
flattened `lca_butterfly` + `lca_modmul` netlist, full 280-case corpus per
mutant):

```text
Corpus mutation coverage: 94.50% (189/200 killed)
```

Survivor characterization (11 total):

- 1 is the `-mode none` unmutated baseline, which survives by
  construction and is counted against coverage only because no
  equivalence filter is configured yet;
- `modulus` bit 0 stuck-at-1 and `multiplicand` bit 23 stuck-at-0 are
  equivalent mutants: both supported moduli are odd, and both are below
  2^23, so those bits are constant in every reachable state;
- four inversions of individual `count` flip-flop slices and three
  post-ABC gate mutations are **open corpus-gap candidates**: they are
  treated as potential defects until the planned sby equivalence filter
  classifies them as equivalent or a corpus extension kills them.

The measured ratio is a lower bound; re-measure after any corpus or RTL
change rather than quoting this number for a different commit.
