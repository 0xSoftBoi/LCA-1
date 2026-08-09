# E1 requirements and traceability

## Scope

These requirements cover the implemented v0 arithmetic slice and its E1
enterprise-foundation controls. `shall` denotes a testable requirement. A row
marked verified means the cited automated evidence exists; it does not expand
the product boundary beyond the single-request butterfly unit.

## Implemented requirements

| ID | Requirement | Implementation | Verification evidence |
|---|---|---|---|
| LCA-FUN-001 | The slice shall select exactly ML-KEM `q=3329` or ML-DSA `q=8380417`. | `rtl/lca_butterfly.sv` | Python differential tests; generated RTL corpus |
| LCA-FUN-002 | For canonical inputs it shall return `(a+bw mod q, a-bw mod q)`. | `model/modarith.py`; `rtl/` | 4,000 randomized Python butterflies; 272 valid RTL cases |
| LCA-IF-001 | A request shall be accepted only on `req_valid && req_ready`, with at most one request in flight. | `rtl/lca_modmul.sv`; `rtl/lca_butterfly.sv` | RTL regression; 24-bit protocol proof |
| LCA-IF-002 | Unsupported modulus IDs and non-canonical operands shall fail closed with `rsp_fault=1` and zero result outputs. | `rtl/lca_butterfly.sv` | 8 malformed corpus cases; full-width formal fault proof |
| LCA-IF-003 | A response shall remain valid and bit-stable while `rsp_ready=0`, and no new request shall be accepted. | `rtl/` | Corpus backpressure holds of 0–3 cycles; formal hold proofs |
| LCA-IF-004 | Active-low synchronous reset shall cancel an in-flight operation and clear the visible response state. | `rtl/` | Mid-operation reset/recovery RTL case |
| LCA-TIM-001 | Every accepted canonical request shall use exactly 24 arithmetic cycles, independent of operand values. | `rtl/lca_modmul.sv` | Every valid RTL vector checks 24 cycles; full-width protocol proof |
| LCA-TIM-002 | The modular multiply loop bound shall depend only on public `WORD_BITS`. | `rtl/lca_modmul.sv`; `model/modarith.py` | source review; reduced-width exhaustive arithmetic proof |
| LCA-VER-001 | The committed RTL corpus shall be reproducible from the golden model with a fixed seed and fail CI on drift. | `tools/gen_vectors.py`; `verification/vectors/` | `python3 tools/gen_vectors.py --check` |
| LCA-VER-002 | Formal scope and limitations shall be documented, and all proof scripts shall fail the build on a counterexample. | `formal/`; `spec/VERIFICATION_PLAN.md` | `make formal`; `reports/formal.log` |
| LCA-BLD-001 | Generic synthesis shall use a lockfile-pinned Yosys runtime and emit reviewable logs, statistics, and netlists. | `package-lock.json`; `synth/`; CI | `make synth`; CI evidence artifact |
| LCA-BLD-002 | Third-party GitHub Actions shall be referenced by immutable commit SHA and dependency updates shall be automated. | `.github/workflows/ci.yml`; `.github/dependabot.yml` | workflow review and CI run |
| LCA-PWR-001 | Accelerator power traces shall validate against the versioned time-domain contract before use by VoltForge. | `spec/power-trace.schema.json`; `model/power_contract.py` | `tests/test_power_contract.py` |
| LCA-CLM-001 | Public claims shall not exceed reproducible artifacts or conflate generic synthesis with target PPA. | README; acceptance and synthesis docs | PR claim-boundary checklist |

## Deferred system requirements

| Gate | Required outcome | Tracking issue |
|---|---|---|
| E1 decision | explicit license, contribution-license terms, and export/public-release posture | [SUW-263](https://linear.app/suwappu/issue/SUW-263) |
| E2 datapath | complete NTT/INTT, memory, Keccak, sampling, packing, command control, self-test, and zeroize | [SUW-264](https://linear.app/suwappu/issue/SUW-264), [SUW-265](https://linear.app/suwappu/issue/SUW-265), [SUW-266](https://linear.app/suwappu/issue/SUW-266) |
| E3 integration | stable descriptor ABI, AXI/DMA, driver/runtime, real ETP backend, named FPGA and measured end-to-end comparison | [SUW-267](https://linear.app/suwappu/issue/SUW-267), [SUW-268](https://linear.app/suwappu/issue/SUW-268), [SUW-270](https://linear.app/suwappu/issue/SUW-270) |
| E4 qualification | physical leakage/fault campaign, independent review, release qualification, and explicit ship/no-ship decision | [SUW-269](https://linear.app/suwappu/issue/SUW-269), [SUW-271](https://linear.app/suwappu/issue/SUW-271) |

No deferred row is satisfied by the E1 artifacts.
