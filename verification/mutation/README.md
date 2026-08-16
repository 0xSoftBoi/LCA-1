# Mutation coverage of the generated corpus

This MCY ([YosysHQ/mcy](https://github.com/YosysHQ/mcy)) project measures
whether the 280-case generated differential corpus would **detect** an
injected netlist-level bug in `lca_modmul` + `lca_butterfly`. Corpus size and
formal scope do not answer that question; mutation testing does.

## What it does

1. Yosys elaborates and flattens the two modules and generates `size` random
   mutations (constant drives, inversions, connection changes) in the
   netlist. The mutation seed is **pinned** in `config.mcy`
   (`seed 480370689` = `0x1ca1e001`, the same value the vector generator
   uses), so the set of 200 mutations is identical on every machine and in
   every run. Without a pinned seed MCY derives one from the wall clock and
   no two campaigns are comparable.
2. `test_sim.sh` replays the full 280-case corpus under Icarus Verilog
   against each mutated netlist. Corpus failure means the mutant was caught.
3. `test_eq.sh` decides, independently of the corpus, whether the mutant is
   distinguishable from the unmutated design **at all**. A mutation that no
   possible test could detect must not be counted against the corpus.
4. The `[logic]` block combines the two into the standard MCY tags and the
   report prints the kill ratio over non-equivalent mutants only.

| corpus | equivalence filter | tag | meaning |
|---|---|---|---|
| kills it | not proven equivalent | `COVERED` | the corpus does its job |
| survives | not proven equivalent | `UNCOVERED` | corpus gap - a defect to close in the generator, until shown otherwise |
| survives | proven equivalent | `NOCHANGE` | undetectable by any test; excluded from the denominator |
| kills it | proven equivalent | `EQGAP` | contradiction: the corpus "caught" a mutant that provably cannot differ. That would indicate a non-deterministic or wrongly specified testbench, not a corpus win |

## The equivalence filter

`test_eq.sh` runs two engines, cheapest first, and returns three values:
`EQUIV`, `DIFFERENT`, or `UNKNOWN`.

1. **ABC `dsec`** on an AIGER miter of the two netlists, both starting from
   the all-zero state - which for this slice is exactly the post-reset state,
   because `rst_n` is synchronous and clears every register. `dsec` is
   reachability-aware, so it settles in well under a second the mutants that
   are equivalent only on reachable states: `u_modmul.modulus` is always odd,
   canonical operands are always below 2^23, `product` never exceeds `q`.
   Pure induction can never close those, because it must survive states the
   machine cannot enter.
2. **yosys `equiv_make` + `equiv_simple -seq 30` + `equiv_induct -seq 30`**
   (`equiv.ys`) when `dsec` is undecided. Temporal induction ignores
   reachability, so it is weaker on the cases above, but it cuts the problem
   at internal equivalence points and closes several deep datapath mutants
   that `dsec` abandons around frame 25.

Neither engine subsumes the other on this design, which is why both run.

`UNKNOWN` is kept distinct from `DIFFERENT` on purpose. `config.mcy` treats
them identically - an undecided mutant stays in the coverage denominator,
which is the conservative direction - but the campaign never quietly rounds
"we do not know" down to "it is fine". The seven `UNCOVERED` mutants are
disposed of individually in [`docs/MUTATION_ANALYSIS.md`](../../docs/MUTATION_ANALYSIS.md).

Only a positive result from an engine is ever believed. Both engines are
sound: a proof is a proof, and everything else leaves the mutant counted
against the corpus.

## Claim boundary

- This layer is a **coverage signal, not an E1 gate**. It runs on a host
  Yosys + Icarus toolchain whose versions are recorded in the run log, not
  the lockfile-pinned Yosys 0.68 used by `make verify`.
- The reported ratio is a lower bound on real corpus strength: `UNKNOWN`
  mutants that are in fact equivalent still count against it.
- A surviving non-equivalent mutant is a corpus gap. File a defect issue
  citing the mutation ID and extend `tools/gen_vectors.py`. **Never
  hand-patch the generated corpus.**
- Mutation coverage measures the corpus against *netlist* mutations of two
  modules. It says nothing about the Python model, the formal properties, the
  Rev-A candidate RTL, or anything physical.

## Running locally

```bash
# prerequisites: yosys (with yosys-abc), iverilog, python3 with click,
# and a clone of YosysHQ/mcy (commit 5a2cad0 or later)
cd verification/mutation
python3 /path/to/mcy/mcy.py init
python3 /path/to/mcy/mcy.py run -j"$(nproc)"
python3 /path/to/mcy/mcy.py status
```

`yosys-abc` ships with the Debian/Ubuntu `yosys` package. If it is absent the
`dsec` stage is skipped with a note and the campaign still runs, using
induction alone - sound, just weaker.

The `database/` and `tasks/` directories are generated state and are not
committed. CI runs this project nightly
(`.github/workflows/mutation.yml`) and uploads the report as an artifact.

Two helper tools support the survivor analysis and are not part of the
campaign:

```bash
bash probe_survivor.sh <mutation_id> [seeds]   # which stimulus dimension exposes it
```

`probe_survivor.sh` drives the unmutated and mutated netlists with identical
stimulus under six profiles (`probe_tb.sv`), from "exactly what the corpus
generates today" up to "every input dimension unconstrained", and reports the
cheapest profile that produces an interface-observable difference. That names
the generator change needed to kill the mutant.

## Measured campaign

Measured 2026-08-16 in the development container: Yosys 0.33
(git sha1 2584903a060) with its bundled ABC 1.01, Icarus Verilog 12.0, MCY
commit `5a2cad0`, 200 mutations of the synthesized flattened
`lca_butterfly` + `lca_modmul` netlist at mutation seed 480370689, full
280-case corpus per mutant, `-j4`.

```text
python3 mcy.py init
python3 mcy.py run -j"$(nproc)"
python3 mcy.py status
```

```text
Database contains 400 cached results.
Database contains 176 cached "DIFFERENT" results for "test_eq".
Database contains 10 cached "EQUIV" results for "test_eq".
Database contains 14 cached "UNKNOWN" results for "test_eq".
Database contains 183 cached "FAIL" results for "test_sim".
Database contains 17 cached "PASS" results for "test_sim".
Tagged 183 mutations as "COVERED".
Tagged 10 mutations as "NOCHANGE".
Tagged 7 mutations as "UNCOVERED".
  -> Print report
Equivalent mutants excluded from the denominator: 10
Corpus mutation coverage: 96.32% (183/190 killed)
```

| measure | value |
|---|---|
| mutations injected | 200 |
| killed by the corpus | 183 |
| survived the corpus | 17 |
| of those, proven equivalent (`NOCHANGE`, excluded) | 10 |
| of those, still counted against the corpus (`UNCOVERED`) | 7 |
| `EQGAP` (killed but provably equivalent) | 0 |
| **coverage, equivalent mutants excluded** | **96.32% (183/190)** |
| raw kill ratio, no equivalence filter | 91.50% (183/200) |

`EQGAP` being empty is a real, if quiet, result: no mutant that the corpus
reported as killed turned out to be provably indistinguishable, so the
testbench did not "detect" anything it could not have detected.

The previous campaign in this file reported 94.50% (189/200). That number is
**not comparable** and is superseded: it was measured with an unpinned,
wall-clock-derived mutation seed, so it describes a different set of 200
mutations, and it had no equivalence filter, so the `-mode none` baseline and
every equivalent mutant counted against it.

Of the seven `UNCOVERED` mutants, four are genuine gaps in two classes, and
three are undecided by both engines but argued equivalent by hand. All seven,
and what would kill the four real ones, are in
[`docs/MUTATION_ANALYSIS.md`](../../docs/MUTATION_ANALYSIS.md).

The campaign's most useful single finding is there rather than in this
number: the fail-closed canonical-range check is exercised at exactly one
point per operand - `operand == q` - by the corpus *and* by the bounded
formal harness `formal/lca_butterfly_fault_formal.sv`. No layer currently
establishes that the slice rejects `q + 1`, `q + 2048`, or an operand with
bit 23 set.

Runtime on 4 cores was 30m49s for the corpus stage plus 20m59s for the
equivalence stage. The nightly workflow's 45-minute job timeout is tight for
that and should be reviewed by whoever owns `.github/workflows/mutation.yml`.

Re-measure after any corpus or RTL change rather than quoting this number for
a different commit.
