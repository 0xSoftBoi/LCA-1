<!-- SPDX-License-Identifier: Apache-2.0 -->

# Mutation survivor analysis

`verification/mutation/README.md` reports the campaign number. This document
disposes of the individual mutants behind it: what each one does to the
netlist, whether it is a real defect-detection gap, and - where it is - the
exact generator change that would close it.

House rule: a surviving mutant is a potential defect until proven equivalent.
Nothing below is dismissed because it looks harmless.

Measured 2026-08-16, Yosys 0.33 (git sha1 2584903a060) with its bundled
ABC 1.01, Icarus Verilog 12.0, MCY commit `5a2cad0`, 200 mutations at
mutation seed 480370689. Mutation IDs are line numbers in
`verification/mutation/database/mutations.txt` and are stable as long as the
seed and the RTL are unchanged.

## Result in one table

| | count |
|---|---|
| mutations injected | 200 |
| killed by the 280-case corpus (`COVERED`) | 183 |
| survived the corpus | 17 |
| survivors proven equivalent (`NOCHANGE`) | 10 |
| survivors not proven equivalent (`UNCOVERED`) | 7 |
| of those seven: disproven equivalent, i.e. **genuine corpus gaps** | 4 |
| of those seven: undecided by the filter, argued equivalent below | 3 |
| `EQGAP` | 0 |
| coverage with equivalent mutants excluded | **96.32% (183/190)** |

**No defect was found in `lca_modmul` or `lca_butterfly`.** Every finding
below is a gap in what the verification *stimulates*, not a bug in what the
RTL *does*.

The two gap classes are not equally contained, and the difference matters:

- **Class B (protocol timing)** is already covered elsewhere. The unbounded
  temporal-induction proofs in `formal/prove.ys` leave every input free, so
  they do exercise `req_valid` asserted while the slice is busy and request
  data changing mid-transaction; invariants B1 and B4 would fail on mutations
  120 and 135. This is a simulation-coverage gap only.
- **Class A (non-canonical operands) is a gap in every layer.** The corpus
  presents an out-of-range operand only at the single point `operand == q`,
  and so does the bounded formal harness: `formal/lca_butterfly_fault_formal.sv`
  drives the fixed request `req_modulus_id=0, req_a=24'd3329` - which is
  exactly `KEM_Q`. Across the whole evidence chain, the fail-closed canonical
  check is verified at one point per operand and nowhere else. Nothing
  currently establishes that it rejects `q + 1`, `q + 2048`, or anything with
  bit 23 set. That is the most useful thing this campaign found.

## How each mutant was classified

| Stage | Tool | Question | Verdict |
|---|---|---|---|
| 1 | `test_sim` - Icarus 12.0 replay of the 280-case corpus | does the committed corpus notice? | FAIL = killed |
| 2a | `test_eq` stage 1 - ABC `dsec` on an AIGER miter of the two netlists from the all-zero (post-reset) state | are the two machines sequentially equivalent? | EQUIV / DIFFERENT / undecided |
| 2b | `test_eq` stage 2 - yosys `equiv_make` + `equiv_simple -seq 30` + `equiv_induct -seq 30` | can temporal induction close it? | EQUIV / UNKNOWN |
| 3 | `probe_survivor.sh` - identical stimulus into both netlists under six profiles; or a yosys `sat` miter when random stimulus is too blunt | which missing stimulus dimension exposes it? | names the generator change |

Two engines because neither dominates. Measured on this design: an
induction-only campaign proved 5 of the 17 survivors equivalent (IDs 1, 19,
71, 169, 195) and left 12 open; adding the reachability-aware `dsec` stage
proved 5 more (100, 108, 132, 171, 191) and left 7. Conversely `dsec` gives
up around frame 25 on some deep datapath mutants that `equiv_induct` closes
in about a minute, so the induction stage still earns its place.

Recorded negative result: ABC's `pdr` was also tried as an engine, on the
same AIGER miter. It reached only frame 22 in 240 s and returned UNDECIDED
even for mutant 71, which `dsec` settles in 0.03 s and `equiv_induct` in
about a minute. It was not adopted.

## Survivors proven equivalent - 10, excluded from the denominator

| ID | mutation | why no test can see it |
|---|---|---|
| 1 | `-mode none` | the unmutated baseline. MCY injects it deliberately; without an equivalence filter it counts against coverage forever, which is most of the gap between the old 94.50% and the new number |
| 19 | `const1` on port A of `$_ANDNOT_ parse_blif$5869` (internal node) | proven by temporal induction |
| 71 | `const0` on port A of `parse_blif$6193`, wire `u_modmul.multiplier[23]` | `multiplier` is loaded from `req_b` only when the request passed canonical validation, so `req_b < q <= 8380417 < 2^23`: bit 23 is 0 in every reachable state |
| 100 | `inv` on port A of `$_NAND_ parse_blif$5960`, inside the `2*multiplicand >= modulus` compare of `add_mod` | `multiplicand` stays below `q`, so the term the inversion perturbs is never the deciding one |
| 108 | `const1` on Q of FF `slice$721`, wire `u_modmul.modulus[0]` | `modulus` is only ever loaded with 3329 or 8380417, both odd. Its reset value 0 is never read, because the only readers are the two `add_mod` adders, which run only while `busy` |
| 132 | `const1` on Y of `$_NOT_ parse_blif$6195` driving `selected_modulus[0]` | same oddness argument on the combinational selector; for the unsupported IDs the comparisons that would see a difference are already gated off by `req_modulus_id <= 2'd1` |
| 169 | `const0` on Y of `parse_blif$5933`, wire `u_modmul.product_next[23]` | the running product is reduced mod `q` every iteration, so it never reaches 2^23 |
| 171 | `inv` on Q of FF `slice$1003`, wire `u_modmul.count[1]` | counter-permutation argument, below |
| 191 | `inv` on Q of FF `slice$1004`, wire `u_modmul.count[2]` | counter-permutation argument, below |
| 195 | `inv` on port B of `$_ORNOT_(u_modmul.modulus[21], u_modmul.multiplicand[15])` | proven by temporal induction |

Note the shape of these: almost all are "this bit is constant in every
reachable state". The 24-bit datapath carries values bounded by a 23-bit
modulus, so the top bit of nearly every operand, product and intermediate is
dead, and a fifth of all mutations that survive the corpus land on one.

## Survivors not proven equivalent - 7

### Genuine corpus gaps: 4, in two classes

The equivalence filter **disproved** equivalence for these four: a
distinguishing input sequence exists, and the corpus does not contain one.

#### Class A - the only out-of-range operand the corpus ever presents is `q` itself

**Mutation 103** - `const0` on port A of `$_NOT_ parse_blif$5388`. In the
netlist that gate is:

```text
cell $_NOT_ $abc$5204$auto$blifparse.cc:386:parse_blif$5388
  connect \A \req_twiddle [23]
  connect \Y $abc$5204$new_n534_
```

so the mutation makes the `req_twiddle < selected_modulus` comparator ignore
bit 23 of `req_twiddle`. Witness from `probe_survivor.sh 103`, profile 3
(operands drawn from the full input space):

```text
profile 0: no difference at all after 1 seed(s) x 100000 cycles
profile 1: no difference at all after 1 seed(s) x 100000 cycles
profile 2: no difference at all after 1 seed(s) x 100000 cycles
profile 3 seed 1: OBSERVABLE DIFFERENCE
      observable difference at cycle 387
        stimulus rst_n=1 req_valid=0 id=1 a=718464 b=6863652 w=15597551 rsp_ready=0
        gold req_ready=0 rsp_valid=1 fault=1 a=0 b=0
        gate req_ready=0 rsp_valid=0 fault=0 a=5754727 b=4062618
```

`w = 15597551` has bit 23 set, so it is far outside `[0, q)`. The unmutated
slice faults; the mutant accepts the request and starts arithmetic. This is
the fail-closed validation path - the one thing the design is supposed to
guarantee about malformed input.

**Mutation 133** - `const0` on port A of `$_ANDNOT_ parse_blif$5325`, a term
in the `req_b < selected_modulus` comparator built from `req_b[16]`,
`req_b[17]` and `selected_modulus[22]`. Random stimulus is too blunt here
(the mis-accepted band is narrow), so the witness came from a bounded miter
instead - `yosys sat -seq 3 -set-init-zero -prove trigger 0 -show-inputs`:

```text
SAT proof finished - model found: FAIL!
  Time Signal Name                                 Dec       Hex
     2 \in_req_a                               8314881    7ee001
     2 \in_req_b                               8382465    7fe801
     2 \in_req_modulus_id                            1         1
     2 \in_req_twiddle                               0         0
     2 \in_req_valid                                 1         1
```

`req_b = 8382465 = q + 2048` for `q = 8380417`. The unmutated slice faults;
the mutant accepts.

**Why the corpus misses both.** `tools/gen_vectors.py` builds exactly eight
malformed cases, and every one of them is either an operand set *exactly
equal* to its modulus (six cases) or an unsupported `modulus_id` with all
operands zero (two cases). So across all 280 cases:

- no operand is ever in the open range `(q, 2^24)`;
- no operand ever has bit 23 set;
- the unsupported modulus IDs are only ever seen with zero operands.

A comparator that is broken anywhere except at the single point `operand == q`
passes the entire corpus.

**Generator change that would kill them** (`tools/gen_vectors.py`, owned
elsewhere): replace the hand-written `invalid_inputs` tuple with a generated
family. For each modulus and each of the three operand positions, emit
out-of-range values chosen to defeat a comparator broken in *any* bit slice,
not just the lowest:

- `modulus + 1` and `modulus + 2` (adjacent, catches the low slices);
- `modulus + 2**11` and `modulus + 2**16` (catches middle slices - mutation
  133 needs exactly this shape);
- `2**23` and `(1 << WORD_BITS) - 1` (catches the top bit - mutation 103
  needs this);
- a few values from `rng.randrange(modulus, 1 << WORD_BITS)` using the
  existing seeded `rng`, so the corpus stays deterministic.

Also emit the unsupported `modulus_id` values 2 and 3 with non-zero operands,
which nothing currently does. That is roughly 3 positions x 2 moduli x 8
values plus a handful of ID cases, so the corpus grows from 280 to about 330
and stays fully deterministic under seed `0x1ca1e001`. Regenerate with
`make vectors`; never edit the committed file.

#### Class B - the corpus never offers a request the slice cannot accept

**Mutation 120** - `const1` on port A of:

```text
cell $_NAND_ $abc$5204$auto$blifparse.cc:386:parse_blif$5477
  connect \A \req_ready
  connect \B \req_valid
```

which makes the request-accept term stop depending on `req_ready`: the mutant
acts on `req_valid` alone. Witness from `probe_survivor.sh 120`, profile 2
(`req_valid` may be asserted while the slice is busy):

```text
profile 0: no difference at all after 1 seed(s) x 20000 cycles
profile 1: no difference at all after 1 seed(s) x 20000 cycles
profile 2 seed 1: OBSERVABLE DIFFERENCE
      observable difference at cycle 23
        stimulus rst_n=1 req_valid=1 id=0 a=128 b=3329 w=2010 rsp_ready=0
        gold req_ready=0 rsp_valid=0 fault=0 a=2167 b=2167
        gate req_ready=0 rsp_valid=1 fault=1 a=0 b=0
```

A malformed request (`b = 3329 = KEM_Q`) is offered while a multiply is in
flight. The unmutated slice ignores it, because `req_ready` is low. The
mutant latches `fault_pending`, asserts `rsp_valid` with `rsp_fault` in the
middle of the transaction and destroys the in-flight operation.

**Mutation 135** - `inv` on port E, the clock enable, of:

```text
cell $_SDFFE_PN0P_ $auto$ff.cc:266:slice$703
  connect \D \req_a [6]
  connect \E \u_modmul.req_valid
  connect \Q \a_saved [6]
```

so `a_saved[6]` now loads on every cycle *except* the acceptance cycle.
Witness from `probe_survivor.sh 135`, again profile 2:

```text
profile 0: no observable difference after 1 seed(s) x 20000 cycles
    (outputs do differ, but only while no response is valid: not corpus-visible)
profile 2 seed 1: OBSERVABLE DIFFERENCE
      observable difference at cycle 26
        stimulus rst_n=1 req_valid=1 id=1 a=4785408 b=8380416 w=7917824 rsp_ready=0
        gold req_ready=0 rsp_valid=1 fault=0 a=2167 b=2167
        gate req_ready=0 rsp_valid=1 fault=0 a=2103 b=2103
```

**Why the corpus misses both.** `verification/tb_lca_butterfly.sv` drives one
transaction at a time:

```systemverilog
@(negedge clk);
while (!req_ready) @(negedge clk);
req_modulus_id = ...; req_a = ...; req_b = ...; req_twiddle = ...;
req_valid = 1'b1;
@(negedge clk);
req_valid = 1'b0;
```

Two consequences. First, `req_valid` is never high while `req_ready` is low,
so nothing checks that an unaccepted request is ignored - which is what hides
mutation 120. Second, `req_a`/`req_b`/`req_twiddle` are left at the accepted
values for the whole 24-cycle multiply, so a register that reloads the same
value one cycle late is indistinguishable - which is what hides mutation 135.

This is worth stating on its own, independently of mutation testing: holding
`valid` asserted until the sink raises `ready` is normal, legal behavior for
a ready/valid source, and no simulation layer in this repository exercises
it. The unbounded induction proofs in `formal/` do cover it - they leave
every input free - so this is a simulation-coverage gap, not a design defect.

**Change that would kill them.** This class cannot be fixed with generator
data alone; the corpus format has no field for request-side timing. The
smallest honest fix is a corpus field plus a testbench behavior:

1. add a deterministic per-case `offer_style` column to
   `tools/gen_vectors.py`, derived like `hold_cycles` is today
   (e.g. `(case_id * 5) % 3`), with three values: 0 = today's behavior;
   1 = assert `req_valid` some cycles *before* the slice is ready and hold it
   until acceptance; 2 = drive a decoy request - different operands,
   preferably a malformed one - on the request bus during the in-flight
   multiply, with `req_valid` asserted;
2. in `verification/tb_lca_butterfly.sv`, implement styles 1 and 2 and assert
   that `req_ready` stays low and no response appears early while the slice
   is busy, and that the eventual response still matches the accepted case.

Style 1 kills mutation 120; style 2 kills mutation 135.

A cheaper interim step needs no format change at all: after the acceptance
cycle, have the testbench scrub `req_a`/`req_b`/`req_twiddle` to their
bitwise complement while `req_valid` stays low. That alone kills mutation 135
and costs one line.

### Undecided by the filter, argued equivalent: 3

These are tagged `UNCOVERED` and counted against coverage, because the
configured filter did not prove them. The arguments below are hand proofs,
recorded so the next person does not have to redo them - they are not tool
output and are not treated as such.

**Mutations 121 and 148** - `inv` on Q of FF `slice$1005` and `slice$1006`,
wires `u_modmul.count[3]` and `count[4]`.

Inverting the Q output of one counter bit means every consumer sees
`c = s XOR 2**k`, while the next stored state is `s' = c + 1`. `count` is
loaded with 0 at request acceptance, so enumerate 24 steps from `s = 0`:

```text
mask  1 (count[0]): 1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 1 3 5 7 9 11 13 15   -> first 23 at step 11
mask  2 (count[1]): 2 1 0 3 6 5 4 7 10 9 8 11 14 13 12 15 18 17 16 19 22 21 20 23   -> first 23 at step 23
mask  4 (count[2]): 4 1 6 3 0 5 2 7 12 9 14 11 8 13 10 15 20 17 22 19 16 21 18 23   -> first 23 at step 23
mask  8 (count[3]): 8 1 10 3 12 5 14 7 0 9 2 11 4 13 6 15 24 17 26 19 28 21 30 23   -> first 23 at step 23
mask 16 (count[4]): 16 1 18 3 20 5 22 7 24 9 26 11 28 13 30 15 0 17 2 19 4 21 6 23  -> first 23 at step 23
mask  0 (unmutated): 0 1 2 3 ... 23                                                  -> first 23 at step 23
```

For bits 1 through 4 the sequence is a permutation that still reaches the
terminal value 23 at exactly step 23 and never before, so the multiplier runs
exactly 24 iterations and the response appears on the same cycle. `count`
fans out only to its own incrementer and to the `count == WORD_BITS-1`
comparator - checked directly in `database/design.il` - and the shift-add
datapath never reads it. The mutants are therefore equivalent.

Three independent checks support this. First, the same argument predicts that
inverting `count[0]` terminates at step 11 instead of 23, changing the
response latency from 24 to 12 - and no `count[0]` mutant survived the
corpus, which checks latency exactly. Second, the campaign's own engines
proved this argument for two of the four cases (mutations 171 and 191,
`count[1]` and `count[2]`) without any help; they simply ran out of budget on
the other two. Third, `probe_survivor.sh` finds no difference of any kind -
not even in don't-care cycles - for either mutant, across all six stimulus
profiles:

```text
########## mutation 121
profile 0: no difference at all after 1 seed(s) x 100000 cycles
...
profile 5: no difference at all after 1 seed(s) x 100000 cycles
########## mutation 148
profile 0: no difference at all after 1 seed(s) x 100000 cycles
...
profile 5: no difference at all after 1 seed(s) x 100000 cycles
```

which is what an equivalent mutant looks like, and is bounded evidence rather
than proof.

**Mutation 160** - `const0` on Y of `$_ANDNOT_ parse_blif$7170` driving
`rsp_b[23]`. Whenever a response is valid, `rsp_b` is either 0 (fault) or
`sub_mod(a_saved, mul_product, modulus_saved)`, reduced modulo
`q <= 8380417 < 2^23`, so bit 23 is 0 and forcing it to 0 changes nothing
observable.

This one is instructive about the filter itself, and it is why the entry says
*protocol*-equivalent rather than equivalent. `rsp_b` is a combinational
output that keeps computing while `rsp_valid` is low, where it carries
mid-transaction garbage whose bit 23 is *not* always 0. `test_eq` compares
every output in every cycle, so it can never return `EQUIV` for this mutant -
no engine budget would help. The prober separates the two notions and
measures exactly that:

```text
profile 0: no observable difference after 1 seed(s) x 100000 cycles
    (outputs do differ, but only while no response is valid: not corpus-visible)
...
profile 5: no difference at all after 1 seed(s) x 100000 cycles
```

The corpus is right not to catch it: `rsp_b` while `rsp_valid` is low is
outside the interface contract, and a test that checked it would be testing
something the design does not promise. Counting this mutant against corpus
coverage is a defect in the *filter*, not in the corpus. Making `test_eq`
mask the response payload with `rsp_valid` before the miter would fix it -
but that weakens the filter for every other mutant, so it should be a
declared second stage rather than a change to the default.

**What would move these from argued to proven.** For 121 and 148 both engines
are stopped by the 24-cycle multiply depth, not by anything conceptual: a
`sby`-driven `prove` run with an explicit counter invariant, or simply a
larger budget, should close them. Mutation 160 needs the filter change
described above, not more compute - strict cycle-by-cycle output equivalence
is the wrong question for a don't-care output.

## What this campaign did not look at

Netlist mutations of two modules, against one corpus. Nothing here bears on
the Python golden model, the zeta ROM, the external CCTV oracle, the Rev-A
candidate RTL, synthesis or physical implementation, or any security
property. And a 96.32% figure is a property of *this* corpus against *this*
mutation set at *this* seed: it is a regression signal, not a grade.
