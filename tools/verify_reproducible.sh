#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Verify every determinism claim this repository makes, end to end.
#
# Reproducible builds are the mandatory companion to any attestation claim
# (docs/DEPIN_LANDSCAPE.md section 8, item 6): a measurement or a signature
# over a non-reproducible artifact proves only that some machine emitted some
# bytes. This script re-derives each generated evidence artifact from its
# committed source and fails if the committed bytes differ.
#
# Invoke as (do not rely on the executable bit being preserved):
#
#     bash tools/verify_reproducible.sh
#
# Exit status is 0 only when every gate passes.

set -u -o pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PYTHON="${PYTHON:-python3}"
VECTOR_CORPUS="verification/vectors/butterfly_vectors.txt"
SBOM="docs/sbom.cdx.json"

GATE_NAMES=()
GATE_RESULTS=()
FAILURES=0

banner() {
    printf '\n== %s ==\n' "$1"
}

run_gate() {
    # run_gate <name> <command...>
    local name="$1"
    shift
    banner "$name"
    printf '$ %s\n' "$*"
    if "$@"; then
        GATE_NAMES+=("$name")
        GATE_RESULTS+=("PASS")
    else
        GATE_NAMES+=("$name")
        GATE_RESULTS+=("FAIL")
        FAILURES=$((FAILURES + 1))
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

banner "environment"
printf 'repository root : %s\n' "$REPO_ROOT"
printf 'python          : %s\n' "$("$PYTHON" --version 2>&1)"
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    printf 'commit          : %s\n' "$(git rev-parse HEAD)"
    printf 'worktree clean  : %s\n' \
        "$(test -z "$(git status --porcelain)" && echo yes || echo no)"
else
    printf 'commit          : unavailable (not a git checkout)\n'
fi

# ---------------------------------------------------------------------------
# 1. Generated regression corpus: regenerate in memory, compare bytes, and
#    print the committed SHA-256 so the value can be quoted in evidence.
# ---------------------------------------------------------------------------
if [ -f "$VECTOR_CORPUS" ]; then
    printf '\ncommitted %s sha256=%s\n' "$VECTOR_CORPUS" "$(sha256_of "$VECTOR_CORPUS")"
fi
run_gate "vector corpus drift" "$PYTHON" tools/gen_vectors.py --check

# ---------------------------------------------------------------------------
# 2. Fabrication contract: semantic validation, then generated-table drift.
# ---------------------------------------------------------------------------
run_gate "fabrication contract validity" "$PYTHON" tools/validate_fabrication.py
run_gate "fabrication artifact drift" "$PYTHON" tools/gen_fabrication_artifacts.py --check

# ---------------------------------------------------------------------------
# 3. SBOM: regenerate in memory and compare against the committed document.
# ---------------------------------------------------------------------------
if [ -f "$SBOM" ]; then
    printf '\ncommitted %s sha256=%s\n' "$SBOM" "$(sha256_of "$SBOM")"
fi
run_gate "sbom drift" "$PYTHON" tools/gen_sbom.py --check

# ---------------------------------------------------------------------------
# 4. Generator determinism: the SBOM generator must be a pure function of the
#    repository, so two independent runs must agree byte for byte.
# ---------------------------------------------------------------------------
banner "sbom generator determinism (two independent runs)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
if "$PYTHON" tools/gen_sbom.py --output "$TEMP_DIR/first.json" >/dev/null \
    && "$PYTHON" tools/gen_sbom.py --output "$TEMP_DIR/second.json" >/dev/null \
    && cmp -s "$TEMP_DIR/first.json" "$TEMP_DIR/second.json"; then
    printf 'identical output, sha256=%s\n' "$(sha256_of "$TEMP_DIR/first.json")"
    GATE_NAMES+=("sbom generator determinism")
    GATE_RESULTS+=("PASS")
else
    printf 'two runs of tools/gen_sbom.py produced different bytes\n' >&2
    GATE_NAMES+=("sbom generator determinism")
    GATE_RESULTS+=("FAIL")
    FAILURES=$((FAILURES + 1))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
banner "summary"
index=0
while [ "$index" -lt "${#GATE_NAMES[@]}" ]; do
    printf '%-6s %s\n' "${GATE_RESULTS[$index]}" "${GATE_NAMES[$index]}"
    index=$((index + 1))
done

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
    printf 'PASS reproducible-evidence verification: %d/%d gates\n' \
        "${#GATE_NAMES[@]}" "${#GATE_NAMES[@]}"
    exit 0
fi

printf 'FAIL reproducible-evidence verification: %d of %d gates failed\n' \
    "$FAILURES" "${#GATE_NAMES[@]}" >&2
printf 'Regenerate with: make vectors; python3 tools/gen_fabrication_artifacts.py; ' >&2
printf 'python3 tools/gen_sbom.py --output %s\n' "$SBOM" >&2
exit 1
