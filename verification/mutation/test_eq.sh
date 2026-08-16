#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# MCY test: decide whether one mutant is functionally equivalent to the
# unmutated design. Three-valued on purpose - "different" and "could not
# decide" are not the same evidence, and collapsing them hides which
# survivors are real.
#
#   EQUIV      proven equivalent: no input sequence from reset can tell the
#              mutant apart, so it must not count against corpus coverage
#   DIFFERENT  disproven: a distinguishing input sequence exists. Having also
#              survived the corpus makes such a mutant a genuine corpus gap
#   UNKNOWN    neither engine decided within its budget. Treated exactly like
#              DIFFERENT by config.mcy - an undecided mutant stays in the
#              coverage denominator - but recorded separately so the campaign
#              never quietly rounds "we do not know" down to "it is fine"
#
# Two engines, cheapest first:
#
#   1. ABC `dsec` on an AIGER miter of the two netlists, both starting from
#      the all-zero state, which for this slice is exactly the post-reset
#      state (rst_n is synchronous and clears every register). dsec is
#      reachability-aware, so it settles the mutants that are equivalent only
#      on reachable states - the modulus-is-odd and operand-below-2^23
#      arguments - which pure induction cannot.
#   2. yosys `equiv_make` + `equiv_simple` + `equiv_induct` when dsec returns
#      undecided. Temporal induction ignores reachability, so it is weaker on
#      those cases, but it closes several deep datapath mutants that dsec
#      gives up on. The two engines are complementary; neither subsumes the
#      other on this design.
#
# Only a positive result from an engine is ever believed. Both engines are
# sound: a proof is a proof, and anything else leaves the mutant in the
# denominator.

exec 2>&1
set -ex

bash "$SCRIPTS"/create_mutated.sh -o mutated.il

# --- stage 1: reachability-aware sequential equivalence (ABC dsec) ---------
aig_script() {  # aig_script <input.il> <output.aig>
    cat <<EOF
read_rtlil $1
hierarchy -top lca_butterfly
flatten
memory_map
async2sync
setundef -undriven -zero -init
opt -full
techmap
opt -fast
dffunmap
abc -g AND -fast
opt_clean -purge
write_aiger -zinit -no-startoffset $2
EOF
}

if ! command -v yosys-abc >/dev/null 2>&1; then
    # yosys-abc ships with the yosys package on Debian/Ubuntu. If it is
    # missing, skip straight to the induction engine rather than failing:
    # the campaign still produces a sound, merely weaker, classification.
    echo "yosys-abc not found - skipping the dsec stage"
    touch dsec.log
fi

aig_script ../../database/design.il gold.aig > gold_aig.ys
aig_script mutated.il gate.aig > gate_aig.ys
if command -v yosys-abc >/dev/null 2>&1; then
    yosys -ql gold_aig.log gold_aig.ys
    yosys -ql gate_aig.log gate_aig.ys

    set +e
    timeout 900 yosys-abc -c "dsec -T 600 gold.aig gate.aig" > dsec.log 2>&1
    set -e
    cat dsec.log
fi

if grep -qi "Networks are equivalent" dsec.log; then
    echo "1 EQUIV" > output.txt
    exit 0
fi
if grep -qi "Networks are NOT EQUIVALENT" dsec.log; then
    echo "1 DIFFERENT" > output.txt
    exit 0
fi

# --- stage 2: temporal induction over an $equiv miter (yosys) --------------
set +e
timeout 1800 yosys -ql equiv.log "$PRJDIR"/equiv.ys
induct_status=$?
set -e

if [ "$induct_status" -eq 0 ]; then
    echo "1 EQUIV" > output.txt
else
    echo "1 UNKNOWN" > output.txt
fi

exit 0
