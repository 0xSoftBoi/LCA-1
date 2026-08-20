#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Independent second front-end lint for the LCA-1 RTL.
#
# Icarus Verilog compiles the regression and Yosys elaborates for synthesis
# and formal. Both accept constructs the other tolerates, and neither reports
# implicit width changes. Verilator is a third, unrelated SystemVerilog
# front-end with an aggressive static-analysis pass, so it is used here purely
# as a cross-check on the same sources.
#
# Two tiers, deliberately:
#
#   gating    the E1 evidence slice (lca_modmul + lca_butterfly), elaborated
#             as a hierarchy with -Wall. It must be warning-free once the
#             waivers in waivers.vlt are applied; any new warning fails.
#   advisory  every other rtl/*.sv. These are Rev-A candidates and shell
#             sources outside the E1 evidence chain; findings are printed and
#             recorded, but they do not fail the run and are never waived.
#
# Exit codes: 0 clean (or verilator unavailable), 1 gating-tier finding.

set -u -o pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LINT_DIR="$REPO_ROOT/verification/lint"
WAIVERS="$LINT_DIR/waivers.vlt"
RTL_DIR="$REPO_ROOT/rtl"

# The two modules that carry E1 claims. Kept explicit rather than globbed:
# the gating set is a decision, not whatever happens to be in the directory.
E1_SOURCES=("$RTL_DIR/lca_butterfly.sv" "$RTL_DIR/lca_modmul.sv")
E1_TOP=lca_butterfly

if ! command -v verilator >/dev/null 2>&1; then
    echo "SKIP: verilator not found on PATH."
    echo "      Install it (Debian/Ubuntu: apt-get install -y verilator) and"
    echo "      re-run. This pass is a cross-check, not an E1 gate, so an"
    echo "      absent tool is reported rather than silently passing."
    exit 0
fi

echo "== tool =="
verilator --version
echo

VFLAGS=(--lint-only -Wall -sv -y "$RTL_DIR" "+incdir+$RTL_DIR")

status=0

echo "== gating tier: E1 evidence slice (top $E1_TOP) =="
if verilator "${VFLAGS[@]}" --top-module "$E1_TOP" "$WAIVERS" "${E1_SOURCES[@]}"; then
    echo "PASS: E1 evidence slice is Verilator-clean under the recorded waivers."
else
    echo "FAIL: Verilator reported an unwaived finding in the E1 evidence slice."
    echo "      Fix the RTL, or add a waiver to waivers.vlt with the argument"
    echo "      written into verification/lint/README.md. Do not waive silently."
    status=1
fi
echo

echo "== advisory tier: sources outside the E1 evidence chain =="
advisory_found=0
for src in "$RTL_DIR"/*.sv; do
    skip=0
    for e1 in "${E1_SOURCES[@]}"; do
        [ "$src" = "$e1" ] && skip=1
    done
    [ "$skip" -eq 1 ] && continue

    name=$(basename "$src")
    # Only the diagnostic header lines: the source echo and the "looked in"
    # search paths make the summary unreadable without adding information.
    out=$(verilator "${VFLAGS[@]}" "$src" 2>&1 |
          grep -E '^%(Warning|Error)' |
          grep -v '^%Error: Exiting due to' |
          sed -e "s#$REPO_ROOT/##" |
          sort -u)
    if [ -z "$out" ]; then
        echo "  clean    $name"
    else
        count=$(printf '%s\n' "$out" | grep -c '^%Warning')
        echo "  $name: $count warning(s)"
        printf '%s\n' "$out" | sed 's/^/      /'
        advisory_found=1
    fi
done

if [ "$advisory_found" -eq 0 ]; then
    echo "  (no advisory findings)"
fi
echo
echo "Advisory findings are informational. They are analyzed in"
echo "verification/lint/README.md and are not waived."

exit "$status"
