.PHONY: test test-python test-rtl

test: test-python test-rtl

test-python:
	python3 -m compileall -q model bench tests
	python3 -m unittest discover -s tests -v
	python3 -m bench.bridge_profile --profile authenticated

test-rtl:
	iverilog -g2012 -Wall -s tb_lca_butterfly -o rtl/simv rtl/lca_modmul.sv rtl/lca_butterfly.sv rtl/tb_lca_butterfly.sv
	vvp rtl/simv
