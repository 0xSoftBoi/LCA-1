#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Characterize one surviving mutant: find the cheapest stimulus dimension the
# 280-case corpus lacks that would separate it from the unmutated design.
#
#   bash verification/mutation/probe_survivor.sh <mutation_id> [seeds]
#
# Requires an initialized MCY database (verification/mutation/database).
# Builds `gold` from database/design.il and `gate` from the mutation with the
# given ID, then runs probe_tb.sv under each profile in turn (see the header
# of probe_tb.sv for what each profile enables).
#
# Per profile the prober reports whether the difference is observable at the
# interface (req_ready/rsp_valid always, response data only while rsp_valid is
# high) or exists only in don't-care cycles. "No difference found" is evidence
# of absence only up to the cycle budget - it is not a proof of equivalence;
# test_eq is what proves that.

set -u -o pipefail

MUT_ID=${1:?usage: probe_survivor.sh <mutation_id> [seeds]}
SEEDS=${2:-3}
CYCLES=${CYCLES:-400000}

PRJDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MUTATION=$(sed -n "${MUT_ID}p" "$PRJDIR/database/mutations.txt")
if [ -z "$MUTATION" ]; then
    echo "no mutation with id $MUT_ID in database/mutations.txt" >&2
    exit 1
fi

echo "mutation $MUT_ID: $MUTATION"
echo

{
    echo "read_rtlil $PRJDIR/database/design.il"
    echo "rename lca_butterfly gold"
    echo "write_verilog -norename $WORK/gold.v"
    echo "design -reset"
    echo "read_rtlil $PRJDIR/database/design.il"
    echo "${MUTATION#mutate }" | sed 's/^/mutate /'
    echo "rename lca_butterfly gate"
    echo "write_verilog -norename $WORK/gate.v"
} > "$WORK/build.ys"

yosys -ql "$WORK/build.log" "$WORK/build.ys" >/dev/null || {
    echo "yosys failed; see $WORK/build.log" >&2
    exit 1
}

iverilog -g2012 -s tb_probe -o "$WORK/sim" \
    "$PRJDIR/probe_tb.sv" "$WORK/gold.v" "$WORK/gate.v" || exit 1

for profile in 0 1 2 3 4 5; do
    for ((s = 1; s <= SEEDS; s++)); do
        out=$(vvp -n "$WORK/sim" "+profile=$profile" "+seed=$s" "+cycles=$CYCLES")
        if printf '%s' "$out" | grep -q '^DIFF'; then
            echo "profile $profile seed $s: OBSERVABLE DIFFERENCE"
            printf '%s\n' "$out" | grep -v '\$finish' | sed 's/^/    /'
            break
        fi
        if [ "$s" -eq "$SEEDS" ]; then
            if printf '%s' "$out" | grep -q '^DONTCARE'; then
                echo "profile $profile: no observable difference after $SEEDS seed(s) x $CYCLES cycles"
                echo "    (outputs do differ, but only while no response is valid: not corpus-visible)"
            else
                echo "profile $profile: no difference at all after $SEEDS seed(s) x $CYCLES cycles"
            fi
        fi
    done
done
