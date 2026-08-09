# Acceptance gates

| Gate | Pass condition | Evidence artifact |
|---|---|---|
| A0 Source | reference workload and commits are pinned | `spec/WORKLOAD.md` |
| A1 Model | modular arithmetic matches Python integer arithmetic for both moduli | unit-test log |
| A2 RTL syntax | SystemVerilog compiles with warnings enabled | CI log |
| A3 RTL equivalence | deterministic butterfly vectors pass for both moduli | simulator log |
| A4 Protocol baseline | real ETP backend passes KAT/negative tests before timing | benchmark manifest |
| A5 End-to-end performance | CPU/GPU/LCA runs include all host transfers and bridge validation | raw JSON traces |
| A6 Power | board instrument, sampling rate, idle subtraction, repetitions are recorded | power trace + report |
| A7 Implementation | named FPGA/ASIC target with tool/version/constraints | synthesis reports |
| A8 Security | malformed input, reset, timeout, zeroize, and fault injection fail closed | adversarial test report |

## Publication rule

A result can appear in the README or public article only if its artifact is in
the repository and the command to reproduce it is documented. Estimates are
labeled estimates; simulations are labeled simulations; measured results name
the instrument and hardware.
