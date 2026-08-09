# Generic synthesis evidence

`synth/lca_generic.ys` parses, elaborates, optimizes, checks, and maps the v0
butterfly into Yosys's generic cell library. CI archives the log, statistics,
JSON netlist, Verilog netlist, and exact tool versions.

Run it with:

```bash
make synth
```

This is a structural synthesis gate. It is **not** FPGA or ASIC PPA evidence:
there is no named device/library, clock constraint, placement, routing,
process/voltage/temperature corner, or physical power model. Those belong to
the named-target E3 gate.
