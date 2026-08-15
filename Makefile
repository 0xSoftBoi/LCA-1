.PHONY: test verify test-python vectors vectors-check test-rtl rtl-test formal synth fabrication-check reuse-lint clean

test: test-python vectors-check test-rtl fabrication-check

verify: test formal synth

test-python:
	python3 -m compileall -q model bench tests tools
	python3 -m unittest discover -s tests -v
	python3 -m bench.bridge_profile --profile authenticated

vectors:
	python3 tools/gen_vectors.py

vectors-check:
	python3 tools/gen_vectors.py --check

test-rtl:
	iverilog -g2012 -Wall -s tb_lca_butterfly -o verification/simv rtl/lca_modmul.sv rtl/lca_butterfly.sv verification/tb_lca_butterfly.sv
	vvp verification/simv

rtl-test: test-rtl

reuse-lint:
	reuse lint

fabrication-check:
	python3 tools/validate_fabrication.py
	python3 tools/gen_fabrication_artifacts.py --check

formal:
	mkdir -p reports
	node --experimental-wasm-exnref tools/run_yosys.mjs -l reports/formal.log -s formal/prove.ys

synth:
	mkdir -p reports
	node --experimental-wasm-exnref tools/run_yosys.mjs -V > reports/yosys-version.txt
	node --experimental-wasm-exnref tools/run_yosys.mjs -l reports/synthesis.log -s synth/lca_generic.ys

clean:
	rm -f verification/simv
	rm -rf reports
