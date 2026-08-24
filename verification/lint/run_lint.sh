#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Independent second front-end lint for the LCA-1 RTL.
#
# Icarus Verilog compiles the regression and Yosys elaborates for synthesis
# and formal. Verilator is a third, unrelated SystemVerilog front-end used to
# catch unsupported constructs, implicit-width changes, and structural issues.
#
# Three tiers:
#
#   gating       the E1 evidence slice (lca_modmul + lca_butterfly), -Wall and
#                warning-free after narrow, documented waivers;
#   elaboration  the Rev-A NTT candidate, which must elaborate with no errors;
#                reviewed arithmetic-width warnings may remain non-fatal until
#                the NTT engine formally enters the claims-bearing chain;
#   advisory     all remaining rtl/*.sv, printed but non-gating.
#
# Exit codes: 0 clean, 1 gating/elaboration failure. A missing Verilator still
# exits 0 for local developer convenience; CI installs it explicitly.

set -u -o pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LINT_DIR="$REPO_ROOT/verification/lint"
WAIVERS="$LINT_DIR/waivers.vlt"
RTL_DIR="$REPO_ROOT/rtl"

E1_SOURCES=("$RTL_DIR/lca_butterfly.sv" "$RTL_DIR/lca_modmul.sv")
E1_TOP=lca_butterfly
NTT_SOURCE="$RTL_DIR/lca_ntt_accel.sv"
NTT_TOP=lca_ntt_accel

if ! command -v verilator >/dev/null 2>&1; then
    echo "SKIP: verilator not found on PATH."
    echo "      Install it (Debian/Ubuntu: apt-get install -y verilator) and"
    echo "      re-run. CI installs Verilator and makes this check mandatory."
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

echo "== elaboration tier: Rev-A NTT candidate (top $NTT_TOP) =="
# Warnings remain visible but non-fatal here. The purpose of this gate is to
# prevent a repeat of BLKLOOPINIT: if the module cannot be elaborated by the
# independent front-end, it cannot enter coverage or the Rev-A evidence chain.
if verilator "${VFLAGS[@]}" --Wno-fatal --top-module "$NTT_TOP" "$NTT_SOURCE"; then
    echo "PASS: Rev-A NTT candidate elaborates under Verilator."
else
    echo "FAIL: Rev-A NTT candidate does not elaborate under Verilator."
    status=1
fi
echo

echo "== advisory tier: sources outside the E1/NTT gates =="
advisory_found=0
for src in "$RTL_DIR"/*.sv; do
    skip=0
    for e1 in "${E1_SOURCES[@]}"; do
        [ "$src" = "$e1" ] && skip=1
    done
    [ "$src" = "$NTT_SOURCE" ] && skip=1
    [ "$skip" -eq 1 ] && continue

    name=$(basename "$src")
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
