<!-- SPDX-License-Identifier: Apache-2.0 -->

# Suwappu S0 product brief

Brief date: 2026-08-26
Program goal: [`GOAL.md`](../GOAL.md)
Silicon release: `LCA1-S0-REV-A` ([`fabrication/rev_a_release.json`](../fabrication/rev_a_release.json))

## What this document is

This is the **product definition** for the Suwappu S0 appliance: the thing the
program intends to sell, written at the completeness a commercial hardware
product page publishes — positioning, architecture, a specification table,
software story, ecosystem, availability, support, and an FAQ.

It is not a datasheet, and no line in it is a claim. S0 has no silicon, no
pilot unit, and no measured number. Every specification below is tagged with
what backs it, and §15 records the exact acceptance gate that would turn each
target into a publishable spec line. `spec/ACCEPTANCE.md` still governs what
may be said in the README, an article, or a post.

The structure follows a shipping edge-compute product page — the
[Arduino VENTUNO Q](https://www.arduino.cc/product-ventuno-q) page as fetched
2026-08-26 — because that page is a fair bar for *completeness of product
definition*: it names its silicon, publishes a full specification table, states
its software stack, enumerates ecosystem compatibility, lists distribution, and
answers ten buyer questions. Matching that bar means answering the same
questions about S0. Where our honest answer is "not decided yet" or "not
measured yet," this brief says so and names the gate, rather than borrowing the
confidence of a product that has shipped.

## 1. Product identity

**Suwappu S0** — a controlled-pilot appliance for privacy-preserving AI
inference bound to bridge and chain state.

One sentence: *an appliance that will not release a model or a session key
until it has verified fresh evidence about what is running, and that emits a
signed receipt binding every inference to a request, a model, a measurement, a
policy, and a chain state.*

| | |
| --- | --- |
| Category | Attested confidential-inference appliance with a bridge/chain policy plane |
| Audience | ETP bridge operators, verifiers, and materializers; one external evaluator at pilot |
| Distinguishing property | Inference receipts bound to attested measurement and chain state |
| Custom silicon | LCA-1 Rev-A — a bounded lattice-arithmetic accelerator, one component of five |
| Pilot target | At least three units, 30 April 2028 ([`GOAL.md`](../GOAL.md) P2 / SUW-299) |
| Current state | Pre-silicon. E1 arithmetic evidence closed; Rev-A boundary in independent review |

S0 is a **composed** system. The custom chip is the smallest of its five
layers, and the product claim does not rest on it alone. Any reading of this
brief that treats LCA-1 as "the secure part" is wrong; §4 and §8 give the real
split.

## 2. How to read this document

Every specification line carries one tag:

| Tag | Meaning |
| --- | --- |
| **EARNED** | An artifact in this repository at this commit backs it. The artifact is linked. |
| **TARGET** | A product decision or intent. No evidence exists. §15 names the gate that would earn it. |
| **OPEN** | Depends on a third party — vendor drawing, foundry acceptance, macro license, external evaluator. Not ours to close by writing code. |
| **TBD** | Not yet decided, and deliberately not invented. The deciding gate is named. |

An untagged sentence is narrative, not specification. Numbers appear only
under EARNED; TARGET and TBD rows carry the decision, not a figure. Inventing a
plausible watt or megahertz to fill a table is the specific failure mode this
tagging exists to prevent.

## 3. Positioning

The market S0 enters is thin and the program says so in writing:
[`docs/DEPIN_LANDSCAPE.md`](DEPIN_LANDSCAPE.md) surveyed the obvious buyer —
decentralized physical infrastructure — and returned a **negative** result for
hardware post-quantum acceleration, including one network that closed a PQC
proposal for lack of demand. [`docs/RELATED_WORK.md`](RELATED_WORK.md) records
that the silicon-proven configurable-lattice-processor niche is already taken.

S0 is therefore not positioned as "a faster PQC chip." It is positioned on the
one property the survey found genuinely missing: **evidence that binds a
computation to the state of the machine that ran it and to the chain it
settles against.** The accelerator exists to make that binding affordable, not
to win a throughput benchmark.

That is a narrow position, and it is the only one the evidence supports.

## 4. Composed architecture

A shipping edge-AI board splits work between an applications processor and a
real-time microcontroller. S0's split is different: it is a **trust**
composition, and the boundary that matters is which layer may see plaintext.

```text
                        ┌──────────────────────────────┐
   client ──session──▶  │  S0 policy plane             │ ── signed receipt ──▶ chain
                        │  evidence verification,      │
                        │  measurement-bound key       │
                        │  release, bridge policy      │
                        └───────┬──────────────┬───────┘
                                │              │
                  ┌─────────────▼──┐      ┌────▼─────────────────┐
                  │ discrete root  │      │ confidential          │
                  │ of trust       │      │ accelerator           │
                  │ identity,      │      │ protected AI          │
                  │ measured boot, │      │ execution and         │
                  │ key custody    │      │ accelerator memory    │
                  └────────────────┘      └───────────────────────┘
                                │
                  ┌─────────────▼────────────────────────────────┐
                  │ LCA-1 Rev-A ASIC                             │
                  │ NTT/INTT · Keccak-f[1600] · modular lane      │
                  │ bounded SRAM · zeroize · self-test           │
                  └──────────────────────────────────────────────┘
```

| Layer | Responsibility | State |
| --- | --- | --- |
| S0 policy plane | Verify evidence, release keys only for approved measurements, apply bridge/chain policy, emit signed receipts | **TARGET** — pinned protocol, golden transcripts, negative vectors and independent review required |
| Discrete root of trust | Device identity, measured boot, counters, lifecycle/debug state, key custody | **TARGET** — part not selected; endorsement/attestation path and adversarial tests required |
| Confidential accelerator | Protected AI execution and accelerator memory | **TARGET** — SKU not selected; attestation, firmware/driver measurement and isolation evidence required |
| LCA-1 Rev-A ASIC | ML-KEM/ML-DSA arithmetic, Keccak, bounded SRAM, command/error handling, zeroization | **EARNED** boundary ([`REV_A_INTEGRATION.md`](REV_A_INTEGRATION.md)); **OPEN** silicon |
| Appliance | Power, board, host, enclosure, update, recovery, test, telemetry, support | **TARGET** — controlled BOM and manufacturing-test record required |

The layer with evidence today is the smallest one. That asymmetry is the
program's actual status, and §15 is where it gets closed.

## 5. LCA-1 Rev-A — the component with evidence

Rev-A is an **accelerator-only** OpenFrame user project. The host owns
standardized-object parsing, algorithm sequencing, keys, bridge policy, chain
state, and the confidential-compute boundary. The die exposes bounded
primitives and nothing else.

### 5.1 Silicon and package

| Item | Value | Tag |
| --- | --- | --- |
| Process | SKY130 | **OPEN** — exact PDK release not pinned |
| Route | ChipFoundry chipIgnite, standard OpenFrame | **OPEN** — published route; no contract or reservation |
| Shell template | Commit `ca732a645568d89efc9db3052eadeca47c60cf4d` | **EARNED** — pinned; vendor acceptance **OPEN** |
| Shuttle | CI2612 | **OPEN** — planning target only, not a reservation |
| User-area budget | 15 mm² | **OPEN** — vendor-published shell limit, *not* an achieved design area |
| Package | 64-pin QFN, 9.0 × 9.0 mm, 0.5 mm pitch, exposed VSS paddle | **OPEN** — datasheet-derived, vendor confirmation required |
| Logical I/O | 44 configurable GPIO, fully allocated | **EARNED** — [`rev_a_gpio_map.csv`](../fabrication/generated/rev_a_gpio_map.csv) |
| Core / pad supplies | `vccd1` 1.8 V core, `vddio` 3.3 V pad and ESD | **EARNED** as rail map; board tie of unused domains **OPEN** |
| Die area, f<sub>max</sub>, power, throughput | — | **TARGET** — no measurement exists; see §15 gate A8/A9 |
| Thermal limits, MSL, ESD class, current limits | — | **OPEN** — require the vendor package qualification sheet |

A known package erratum is carried openly: the pinned OpenFrame datasheet's
Figure 2 maps pin 31 to `gpio[0]` and pin 38 to `vssa1`, while a later text row
mistakenly lists pin 31 under `vssa1`. This release follows Figure 2 and blocks
package freeze until ChipFoundry confirms in writing.

### 5.2 Host interface — LCA-LINK-16

| Item | Value | Tag |
| --- | --- | --- |
| Link | One synchronous 16-bit multiplexed request/response bus | **EARNED** |
| Signals | 16 data, 8 address/channel, req valid/ready/write/last, rsp valid/ready/last, IRQ, tamper, zeroize, busy, fault, zeroize-busy, self-test-fail, one clock, five disabled reserves | **EARNED** |
| Clock | Single external `host_clk` (QFN pin 22) — the only functional clock | **EARNED** |
| Reset | OpenFrame `resetb_l` (QFN pin 21), outside the GPIO budget | **EARNED** |
| Outstanding reads | Exactly one | **EARNED** |
| Debug / factory test port | **None bonded** — production test uses the same host link | **EARNED** |
| Identity / ABI | `IDENTITY` = `0x4c434131`, `ABI_VERSION` = `0x0001` | **EARNED** |
| Link clock rate | — | **TARGET** — unmeasured until routed STA exists |

The full cycle contract, CSR map, `STATUS`/`CONTROL` bit definitions, and
address classes are frozen in [`REV_A_INTEGRATION.md`](REV_A_INTEGRATION.md)
and machine-checked by `make fabrication-check`.

### 5.3 Primitives and data channels

| Command | Parameters | Tag |
| --- | --- | --- |
| ML-KEM NTT / INTT | `n=256`, `q=3329` | **EARNED** as boundary |
| ML-DSA NTT / INTT | `n=256`, `q=8380417` | **EARNED** as boundary |
| Keccak-f[1600] permutation | 200-byte state | **EARNED** as boundary |
| Bounded modular arithmetic | Dual-modulus lane | **EARNED** — v0 slice characterized |
| Self-test | Startup and commanded | **EARNED** as boundary |

| Channel | Direction | Exact transfer unit |
| --- | --- | ---: |
| NTT coefficient write / read | host ↔ chip | 1,024 bytes |
| Keccak state write / read | host ↔ chip | 200 bytes |
| SRAM write / read | host ↔ chip | bounded by selected SRAM and cursor |

There is **no** decapsulation, signing, verification, model execution, or other
whole-algorithm command. No externally supplied message, signature, ciphertext,
public key, or secret key is retained as a complete object — the host streams
only bounded primitive state.

### 5.4 Memory

| Item | Value | Tag |
| --- | --- | --- |
| Baseline | One `CF_SRAM_8192x32` — 32 KiB, published macro area 1.34 mm² | **OPEN** — commercial views, license, timing model and repair/test behavior not acquired |
| Experiment | Two identical instances — 64 KiB | **OPEN** — promoted only if it closes area, all timing corners, congestion, IR/EM, zeroize coverage and cost |
| Macro selection | — | **OPEN** — OpenRAM, SRAM22 and the commercial macro all remain evidence-gated; see [`SRAM_DECISION.md`](SRAM_DECISION.md) |

The 64 KiB experiment is not permission to restore the removed whole-message
frontend.

### 5.5 What is verified today

| Layer | Evidence | Tag |
| --- | --- | --- |
| Workload boundary | ETP commit and primitive call sites pinned in [`spec/WORKLOAD.md`](../spec/WORKLOAD.md) | **EARNED** |
| Golden model | 4,000 randomized modular multiplies and 4,000 butterflies, both production moduli | **EARNED** |
| RTL | Synthesizable 24-bit constant-iteration multiplier and butterfly, fail-closed canonical validation | **EARNED** |
| Generated regression | 280 deterministic full-width cases — 272 valid, 8 malformed, backpressure, exact latency, reset/recovery | **EARNED** |
| Formal | Exhaustive four-bit arithmetic at `q=13`; full-width latency/hold and invalid-input proofs | **EARNED within documented scope** |
| Structural synthesis | Lockfile-pinned Yosys 0.68 generic mapping, zero structural problems | **EARNED** — a regression signal, *not* FPGA or ASIC area |
| Manufacturing contract | Pinned route, complete 64-QFN table, all 44 GPIOs, pad modes, SRAM variants, assembly blockers, 11 stable tests | **EARNED** |

Reproduce with `npm ci --ignore-scripts && make verify`.

## 6. Appliance specifications

Every row here is a **P0 freeze deliverable** (30 September 2026, SUW-298).
None is decided. Publishing a plausible value now would be the exact failure
`spec/ACCEPTANCE.md` forbids.

| Item | State | Closes at |
| --- | --- | --- |
| Host processor and platform | **TBD** | P0 — product and trust freeze |
| Discrete root-of-trust part | **TBD** — must have a supported endorsement/attestation path | P0 |
| Confidential-accelerator SKU | **TBD** — must have selected-SKU attestation and isolation evidence | P0 |
| System memory and storage | **TBD** | P0 |
| Network interfaces | **TBD** | P0 |
| LCA-1 attachment | M.2 assembly or evaluation-board carrier | **OPEN** — CI2612 evaluation-board and M.2 daughter-card revisions not received |
| Power input and budget | **TBD** | P0, then measured at P1 |
| Enclosure and dimensions | **TBD** | P0 |
| Thermal design | **TBD** | Requires the package thermal model — **OPEN** on vendor |
| Controlled BOM with lifecycle status | **TARGET** | P2 — pilot |
| Signed software image and serialization | **TARGET** | P2 |
| Manufacturing-test record | **TARGET** | P2 |

### 6.1 Reference workload

The unit of work S0 is specified against is **one authenticated bridge
operation** — not a raw transform count.

| Phase | Primitive | Count |
| --- | --- | ---: |
| COMMIT | ML-DSA-65 sign | 1 |
| LATTICE | ML-KEM-768 encapsulate | 1 |
| RELAY | ML-DSA-65 sign | 0 or 1 |
| MATERIALIZE | ML-KEM-768 decapsulate | 1 |
| MATERIALIZE | ML-DSA-65 verify | 1 |
| MATERIALIZE | ML-DSA-65 verify (relay envelope) | 0 or 1 |

Headline metrics, when they exist, are completed authenticated bridge
operations per second; p50/p95/p99 end-to-end latency; joules per completed
operation; peak and sustained board power. **Raw NTT throughput is a
diagnostic, not a headline.** No figure may be quoted until the harness proves
a real FIPS-conformant backend is active with matching parameter sets and
passing known-answer and negative tests — the gate in
[`spec/WORKLOAD.md`](../spec/WORKLOAD.md).

## 7. Host software and developer experience

A product page's software section answers: what do I install, what do I write,
and what runs where. S0's answers:

| Element | Content | Tag |
| --- | --- | --- |
| Algorithm ownership | **The host owns complete algorithms.** LCA-1 accelerates primitives; it never sequences ML-KEM or ML-DSA | **EARNED** boundary |
| Reference runtime | [Entanglement Transfer Protocol](https://github.com/0xSoftBoi/Entanglement-Transfer-Protocol), pinned at commit `36b3c97` | **EARNED** |
| Driver / host model | Cycle-accurate LCA-LINK-16 host model agreeing cycle-for-cycle with the integration contract | **TARGET** — a named T0 review exit condition |
| Command surface | An 11-register CSR map (`0x00`–`0x0e`) and 6 sequential data channels; no microcode, no arbitrary opcodes | **EARNED** |
| Failure semantics | Fail-closed and sticky: an accelerator error can never be reinterpreted as a valid signature, successful decapsulation, or finalized message | **EARNED** as required control |
| Fallback | If LCA-1 is absent, times out, resets or faults, the host falls back to a known-good software implementation or rejects the operation | **EARNED** as required control |
| Power telemetry | Versioned time-domain trace, schema at [`spec/power-trace.schema.json`](../spec/power-trace.schema.json), consumed by [VoltForge](https://github.com/0xSoftBoi/GaN-optimization-) | **EARNED** as contract; measured traces **TARGET** |
| Policy-plane SDK | Session establishment, key release, receipt emission | **TARGET** — P1 deliverable |
| Update, recovery, telemetry procedures | — | **TARGET** — P2 deliverable |

S0 exports a workload-shaped power trace rather than inventing a TDP. An
estimated trace may guide exploration; only a measured trace may support an
efficiency claim.

## 8. Security model

This is the section where S0 differs most from a general-purpose edge board,
and it is also where the strongest discipline applies.

### 8.1 Assets and adversaries

Assets: ML-KEM decapsulation keys and shared secrets; ML-DSA signing keys and
sensitive intermediates; plaintext lattice-key payloads and CEKs; correctness
of verification results; availability of the bridge verifier without fail-open
behavior.

Adversaries: malicious host process, malicious bridge input, bus observer,
physical attacker, supply-chain attacker
([`spec/THREAT_MODEL.md`](../spec/THREAT_MODEL.md)).

### 8.2 Controls implemented at the Rev-A boundary — EARNED as contract

- Constant-iteration arithmetic with no secret-dependent early exit.
- Strict length and canonical-residue checks; a non-canonical operand returns a
  fault with zero outputs and never starts arithmetic.
- Fail-closed, sticky errors that do not mutate accelerator or SRAM state.
- `tamper_n` is **active-low fail-safe** and asynchronously latching: a broken
  connection to the host or security controller fails *into* the tamper state.
- Full scrub after reset, on abort, on host zeroize, and on tamper — clearing
  every selected SRAM bank, retained Keccak lane, NTT coefficient, arithmetic
  register, cursor, response register, and error field.
- No bonded debug-unlock or factory-test-mode signal; five reserve pads have
  both buffers disabled, so there is no hidden test mode.

A documented Rev-A limitation, stated rather than hidden: a die with no clock
cannot physically rewrite SRAM, so scrubbing resumes when `host_clk` returns.
That is a limitation, not a TEE property.

### 8.3 Appliance-level security — TARGET

The properties the *product* is sold on are not the chip's:

- Client and device establish an encrypted session bound to **fresh**
  attestation.
- Model and session keys release only for approved measurements and policy.
- Every memory, DMA, and software domain where plaintext may exist is **named**.
- Stale or replayed evidence, relay, downgrade, debug, rollback, reset,
  component replacement, and malformed DMA all **fail closed**.
- Inference receipts bind request hash, model hash, measurement, policy, result
  hash, and chain state.
- Bridge and chain proof verification share the same attested policy boundary.

Each is a P1 exit condition with adversarial evidence required, not a feature
that exists today.

### 8.4 Measured leakage baseline

[`docs/LEAKAGE_METHODOLOGY.md`](LEAKAGE_METHODOLOGY.md) records a pre-silicon
fixed-vs-random leakage baseline and its limits. It is a methodology and a
starting measurement — it is not a side-channel resistance claim, and Rev-A is
explicitly **not a masked implementation**.

## 9. What S0 is not

Stated as flatly as the specifications, because a security product that is
vague here is dishonest:

- **Not a root of trust.** That is a discrete component, still unselected.
- **Not a TEE**, and LCA-1 is not a trusted execution environment of any kind.
- **Not an autonomous PQC SoC.** There is no CPU, no firmware ROM, and no
  whole-algorithm command on Rev-A.
- **Not a masked implementation**, and not resistant to power, EM, or
  fault-injection attacks.
- **Not certified.** No FIPS 140-3 validation, no CMVP certificate, no
  FCC/CE/RoHS status, no safety rating.
- **Not a competitive AI accelerator.** LCA-1 executes no model.
- **Not secure key storage.** Keys live with the host and the root of trust.
- **Not safe for a money-moving bridge** until fault-injection and adversarial
  evidence exists.
- **Not fabricated.** Simulation, FPGA results, generated GDS, internal
  signoff, wafer delivery, or an uncharacterized chip do not complete the goal.

No "×faster," energy, area, frequency, production-security, certification, TEE,
private-inference, or tapeout claim belongs in any S0 material without a
reproducible artifact for the exact system boundary.

## 10. Applications

Scoped to the pilot, not aspirational:

1. **ETP bridge verification** — relayers, materializers and verifiers running
   the authenticated path of §6.1 with receipts bound to chain state.
2. **Measurement-gated model serving** — a model whose keys release only to an
   appliance whose measurement matches policy.
3. **Auditable inference** — workloads where the receipt, not the throughput,
   is the product.
4. **Independent evaluation** — one unit delivered to an external evaluator
   under an owner-approved written test plan (a P2 completion condition).

Deliberately excluded: general edge AI, robotics, and consumer or maker use.
The maker channel was surveyed and found to be decaying
([`DEPIN_LANDSCAPE.md`](DEPIN_LANDSCAPE.md) §7).

## 11. Ecosystem and integration

| Interface | Contract | Tag |
| --- | --- | --- |
| ETP bridge runtime | Pinned commit and primitive call sites | **EARNED** |
| VoltForge power analysis | Versioned time-domain trace schema | **EARNED** as contract |
| Suwappu settlement policy | Post-quantum settlement stays disabled until bridge, verifier, execution client, conformance vectors, provider, executor and testnet gates pass — **LCA-1 weakens none of them** | **EARNED** as policy |
| Host carrier | M.2 assembly or evaluation board | **OPEN** — vendor board revisions not received |
| Third-party integration | Apache-2.0 first-party code with an explicit patent grant, so integrators and foundry partners can evaluate without a separate agreement | **EARNED** |

The license is a copyright and patent grant, not a fitness claim. `SECURITY.md`
and [`spec/THREAT_MODEL.md`](../spec/THREAT_MODEL.md) still bound every use.

## 12. Availability and ordering

| | |
| --- | --- |
| Status | **Not available.** No pre-order, no price, no lead time, no distributor. |
| Silicon | Not fabricated. No shuttle reservation and no purchase commitment exists. |
| Pilot | At least three units under a controlled BOM, target 30 April 2028 |
| Distribution | None. The pilot is controlled; one unit goes to an external evaluator |
| Vendor delivery basis (published offer, not contracted) | 100 QFN parts, ten M.2 assemblies, one evaluation board |
| NRE, COGS, price, lead time, EOL, export, licensing, single-source risk | **TARGET** — all are P2 documentation conditions |

Nothing in this brief authorizes vendor contact, reservation, payment,
agreement acceptance, restricted-material access, waiver approval, external
shipment, or mask release. Those are Toma's, and only in writing.

## 13. Compliance, support and lifecycle

| Item | State |
| --- | --- |
| FIPS 140-3 / CMVP | **Not held, not in progress.** Requires a defined module boundary, physical device, laboratory evidence, validated entropy and key management, and independent review |
| FCC / CE / RoHS | **TBD** — no enclosure or radio decision exists yet |
| ESD, MSL, reflow, storage limits | **OPEN** — require the vendor package qualification sheet |
| Standards conformance | ML-KEM-768 to [FIPS 203](https://doi.org/10.6028/NIST.FIPS.203), ML-DSA-65 to [FIPS 204](https://doi.org/10.6028/NIST.FIPS.204). Both have published errata; every conformance run records the revision and errata date it used |
| Vulnerability handling | `SECURITY.md` |
| Support policy | `SUPPORT.md`; product-grade support, update, recovery, telemetry, errata and failure-analysis procedures are **TARGET** at P2 |
| Versioning | `VERSIONING.md`; claims are bounded per commit, so citations must pin the exact commit |
| Traceability | Physical evidence records sample and unit IDs; lot, wafer, die coordinate, package and assembly lot, board serial, and test version |

## 14. FAQ

**Can I buy one?**
No. There is no silicon, no price and no distributor. §12.

**Is LCA-1 taped out?**
No. The Rev-A boundary is ready for independent T0 review. T1 through T4, T6
and T7 are blocked; T5 is in progress. §15.

**How fast is it? How much power does it use?**
Unknown, and deliberately unpublished. No routed timing, no board measurement,
no packaged part. Generic synthesis output is a regression signal, not area.
Gates A7–A9 in §15.

**Does the chip perform ML-KEM or ML-DSA?**
No. It performs NTT/INTT, Keccak-f[1600] and bounded modular arithmetic. The
host sequences the algorithms and owns the keys. §5.3.

**Is it a secure enclave or TEE?**
No. §9. The confidential-compute boundary belongs to a separate, unselected
component. §4.

**Is it side-channel resistant?**
No. Constant-iteration arithmetic and a measured leakage *baseline* exist;
resistance to power, EM or fault injection does not. §8.4.

**Is it FIPS certified?**
No, and no validation is in progress. §13.

**What happens if the accelerator fails or disappears?**
The host falls back to a known-good software implementation or rejects the
operation. An accelerator error is never reinterpreted as a valid signature,
successful decapsulation or finalized bridge message. §7.

**Why is the memory only 32 KiB?**
Because Rev-A is accelerator-only. The host streams bounded primitive state —
one 256-coefficient polynomial, one 200-byte Keccak state, or an addressed SRAM
range — so no whole message, key, ciphertext or signature is ever resident. A
64 KiB variant is a measured experiment, not a plan. §5.4.

**What does S0 offer that a general-purpose confidential-compute box doesn't?**
The receipt: a signed binding of request hash, model hash, measurement, policy,
result hash and chain state, verified against the same policy boundary the
bridge uses. That is the claim the pilot exists to test — and it is TARGET, not
a shipping feature. §8.3.

## 15. Publication gate register

The map from every TARGET in this brief to the gate that would let it be
stated. Chip gates are from [`fabrication/rev_a_release.json`](../fabrication/rev_a_release.json);
claim gates from [`spec/ACCEPTANCE.md`](../spec/ACCEPTANCE.md); program gates
from [`GOAL.md`](../GOAL.md).

### Rev-A silicon gates

| Gate | Scope | Status | Blocked by |
| --- | --- | --- | --- |
| T0 | Boundary and interface | ready for independent review | — |
| T1 | Memory area and timing | blocked | T0 review; commercial SRAM views/license |
| T2 | OpenFrame hardening smoke | blocked | T1 selected memory; Rev-A RTL top |
| T3 | Commercial and legal route | blocked | quote; contract; reservation authority; IP terms |
| T4 | Signoff release | blocked | RTL/GL verification; STA; DRC; LVS; antenna; IR/EM; `cf precheck` |
| T5 | Package, board, test | in progress | — |
| T6 | Vendor submission and acceptance | blocked | T3; T4; T5; explicit mask-release authority |
| T7 | First-silicon characterization | blocked | packaged silicon delivery |

Nine package freeze blockers remain **OPEN on ChipFoundry**, including shell-commit
confirmation, the pin-31/pin-38 erratum, the controlled mechanical drawing,
thermal and parasitic models with per-pin and per-rail current limits, package
qualification data, evaluation-board and M.2 revisions, post-route SSO/IR/EM and
signal-integrity review, test quotes, and the final bond and marking plan.

### Claim gates

| Gate | Unlocks | State |
| --- | --- | --- |
| A0–A5 | Workload pin, model, corpus, RTL, formal, structural synthesis | **earned** (A4 within documented scope; A5 is not target PPA) |
| A6 | Protocol baseline — real ETP backend passes KAT and negative tests before timing | open |
| A7 | End-to-end performance, including host transfers and bridge validation | open |
| A8 | Physical implementation on a named target with tools, constraints, P&R and timing | open |
| A9 | Power — instrument, sampling, idle subtraction, repetitions, temperature, regulator path | open |
| A10 | Security — malformed DMA, reset, timeout, zeroize, leakage, fault injection fail closed | open |
| A11 | Qualification — independent review approves the exact release claims | open |

### Program gates

| Gate | Target | Turns TARGET into spec for |
| --- | --- | --- |
| P0 — product and trust freeze | 30 Sep 2026 | §6 appliance rows; §4 component selection; §3 claims and economics |
| P1 — reference appliance | 31 Jan 2027 | §8.3 attestation, key release, receipts; §7 policy-plane SDK; §6.1 first measured numbers |
| E1–E4 / T0–T6 | through Apr 2028 | §5 silicon specifications |
| P2 — controlled pilot | 30 Apr 2028 | §6 BOM and manufacturing test; §12 commercial terms; §13 support and lifecycle |

An evidence-backed **NO-GO**, **NEXT SHUTTLE**, **REDUCE** or **PIVOT** is a
legitimate outcome of any of these gates, and program success. Shipping a false
security claim is failure.

## 16. Sources

- [`GOAL.md`](../GOAL.md) — program goal, layer split, execution gates, stop conditions, authority
- [`docs/REV_A_INTEGRATION.md`](REV_A_INTEGRATION.md) — Rev-A boundary, LCA-LINK-16 cycle contract, CSR map, reset/tamper/zeroize semantics
- [`docs/FABRICATION_AND_PACKAGE.md`](FABRICATION_AND_PACKAGE.md) — route, package disposition, board contract, ATE flow, external gates
- [`docs/PRE_SILICON_STATUS.md`](PRE_SILICON_STATUS.md) — what is closed in the repository and what is deliberately not claimed closed
- [`docs/SRAM_DECISION.md`](SRAM_DECISION.md) — memory options, measured geometry, undecided criteria
- [`docs/LEAKAGE_METHODOLOGY.md`](LEAKAGE_METHODOLOGY.md) — measured leakage baseline and its limits
- [`docs/DEPIN_LANDSCAPE.md`](DEPIN_LANDSCAPE.md) — market survey and its negative finding
- [`docs/RELATED_WORK.md`](RELATED_WORK.md) — surveyed PQC-hardware landscape and defended position
- [`spec/WORKLOAD.md`](../spec/WORKLOAD.md) — reference workload, pinned parameters, real-backend gate, acceptance metrics
- [`spec/THREAT_MODEL.md`](../spec/THREAT_MODEL.md) — assets, adversaries, required controls, claim boundary
- [`spec/ACCEPTANCE.md`](../spec/ACCEPTANCE.md) — acceptance gates and the publication rule
- [`spec/POWER_CONTRACT.md`](../spec/POWER_CONTRACT.md) — power trace contract with VoltForge
- [`fabrication/rev_a_release.json`](../fabrication/rev_a_release.json), [`fabrication/rev_a_package.json`](../fabrication/rev_a_package.json) — machine-readable release and package state
- [Arduino VENTUNO Q product page](https://www.arduino.cc/product-ventuno-q) — the product-definition completeness bar this brief was written against, fetched 2026-08-26
