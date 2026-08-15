#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# MCY test: replay the full 280-case generated corpus against one mutant.
# PASS  -> the mutant survived the corpus (mutation not detected)
# FAIL  -> the corpus caught the mutant (this is the desired outcome)

exec 2>&1
set -ex

bash "$SCRIPTS"/create_mutated.sh

# The testbench opens the corpus via a repo-relative path; recreate it
# inside the task sandbox.
mkdir -p verification/vectors
cp "$PRJDIR"/../vectors/butterfly_vectors.txt verification/vectors/

iverilog -g2012 -s tb_lca_butterfly -o sim \
    "$PRJDIR"/../tb_lca_butterfly.sv mutated.v
vvp -n sim > sim.out || true

if grep -q "PASS lca_butterfly corpus" sim.out; then
    echo "1 PASS" > output.txt
else
    echo "1 FAIL" > output.txt
fi

exit 0
