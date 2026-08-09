# Acceptance gates

| Gate | Pass condition | Evidence artifact | State |
|---|---|---|---|
| A0 Source | reference workload and commits are pinned | `spec/WORKLOAD.md` | earned |
| A1 Model | arithmetic matches Python integers for both production moduli | unit-test log | earned |
| A2 Corpus | deterministic generated corpus matches the committed 280 cases | generator drift log | earned |
| A3 RTL | full-width outputs, 24-cycle latency, malformed input, backpressure, and reset pass | simulator log | earned |
| A4 Formal | reduced arithmetic, full-width control/hold, and full-width rejection proofs have no counterexample | `reports/formal.log` | earned within documented scope |
| A5 Structural synthesis | pinned Yosys elaborates/maps/checks the design and emits artifacts | synthesis log/stat/netlists | earned; not target PPA |
| A6 Protocol baseline | real ETP backend passes KAT/negative tests before timing | benchmark manifest | open |
| A7 End-to-end performance | CPU/GPU/FPGA runs include all host transfers and bridge validation | raw JSON traces | open |
| A8 Physical implementation | named FPGA/ASIC target has tool/version/constraints, P&R and timing evidence | implementation reports | open |
| A9 Power | board instrument, sampling, idle subtraction, repetitions, temperature, and regulator path are recorded | power trace + report | open |
| A10 Security | malformed DMA, reset, timeout, zeroize, leakage, and fault injection fail closed | adversarial and lab reports | open |
| A11 Qualification | independent review closes/accepts findings and approves exact release claims | signed decision/evidence index | open |

## Publication rule

A result can appear in the README, article, or social post only if its artifact
is tied to the exact source commit and its reproduction command is documented.
Estimates, simulations, generic synthesis, FPGA measurements, and ASIC
measurements remain explicitly distinct. A bounded formal proof is described
with its width, assumptions, property, and depth.

No speedup, PPA, physical-security, production-readiness, or certification
claim is permitted until its corresponding open gate is earned.
