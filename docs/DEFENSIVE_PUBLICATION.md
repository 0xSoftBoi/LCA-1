# Defensive publication

**Published 2026-08-16 by the LCA-1 project (`0xSoftBoi/LCA-1`).**

This document is a deliberate defensive publication. Its purpose is to
place the technical subject matter below into the public prior art on the
date of publication, so that it remains freely practicable and cannot later
be removed from the public domain by a third party's patent.

The project **forgoes patent protection on everything disclosed here**, and
that choice is intentional and irreversible. It follows a prior-art search
that found four of five candidate concepts already anticipated, and it
follows this program's general position that its defensible assets are
reproducible evidence and open implementation rather than exclusionary
rights.

The disclosures below are written to be **enabling**: sufficient for a
person skilled in hardware verification or secure-element design to
practise them without undue experimentation. Where a concept is already
anticipated by earlier art, that art is named. Naming it is deliberate —
it marks precisely where the remaining delta is, and that delta is what
this publication protects.

This is an engineering document, not legal advice. Parties needing a
formal, indexed disclosure record should also lodge these with an
established venue (IP.com, Research Disclosure) or a timestamped archive.

---

## 1. Equivalence-filtered mutation coverage for hardware verification

### 1.1 Problem

Mutation testing measures whether a test suite would *detect* an injected
defect, which neither suite size nor formal proof scope answers. Its
long-standing defect is the **equivalent mutant**: a mutation that changes
the netlist but cannot change observable behaviour, and therefore cannot be
detected by any possible test. Counting equivalent mutants as failures
understates test-suite strength by an unknown margin, so the reported
coverage number is not trustworthy.

### 1.2 Disclosed method

A verification method combining three stages, where the third is the
novel element:

1. **Mutation injection into a synthesized netlist.** Elaborate and flatten
   the design under test, then generate a set of mutations (constant
   drives, signal inversions, connection changes) at a **pinned seed**, so
   the mutation set is reproducible across machines and runs. An unpinned,
   wall-clock-derived seed makes two campaigns incomparable and any reported
   ratio unreproducible.
2. **Differential corpus replay.** Replay a deterministic, generated
   input/expected-output corpus against each mutated netlist in simulation.
   Corpus failure means the mutant was detected.
3. **Independent formal equivalence exclusion — the disclosed element.**
   For each mutant, decide *independently of the corpus* whether the mutant
   is distinguishable from the unmutated design at all, and exclude
   provably-indistinguishable mutants from the coverage **denominator**,
   yielding a corrected coverage figure.

### 1.3 The two-engine exclusion oracle

The exclusion oracle uses two complementary engines because neither
subsumes the other on sequential arithmetic designs. It returns three
values: `EQUIV`, `DIFFERENT`, `UNKNOWN`.

**Engine A — reachability-aware sequential equivalence checking.**
Construct an AIGER miter of the mutated and unmutated netlists and run a
sequential equivalence check (e.g. ABC `dsec`) with **both machines started
from the all-zero state**, which for a design with synchronous reset
clearing every register is exactly the post-reset state. Because this
engine reasons over *reachable* states, it settles quickly the large class
of mutants that are equivalent only under reachability invariants — for
example, where a modulus register is always odd so its low bit is constant,
where canonical operands are bounded below a power of two so high bits
never toggle, or where an accumulator never exceeds a modulus. Pure
induction can never close these, because induction must survive states the
machine cannot enter.

**Engine B — temporal induction with internal equivalence points.**
Where Engine A is undecided, run structural equivalence-point matching
followed by simple and inductive sequential equivalence over a bounded
depth (e.g. Yosys `equiv_make`, `equiv_simple -seq N`, `equiv_induct -seq
N`). This engine ignores reachability, so it is weaker on the class above,
but it cuts the problem at internal equivalence points and closes deep
datapath mutants that Engine A abandons at greater depth.

**Soundness discipline.** Only a positive proof from an engine is believed.
`UNKNOWN` is kept distinct from `DIFFERENT` in the record but is treated
identically in the metric — an undecided mutant **remains in the coverage
denominator**, so the reported figure is a lower bound on true suite
strength. The method never rounds "undecided" down to "equivalent".

### 1.4 Four-way classification and the corrected metric

Cross the two independent results:

| Corpus | Equivalence oracle | Tag | Meaning |
|---|---|---|---|
| kills | not proven equivalent | `COVERED` | suite detects a real behavioural change |
| survives | not proven equivalent | `UNCOVERED` | genuine suite gap; a defect until shown otherwise |
| survives | proven equivalent | `NOCHANGE` | undetectable by any test; **excluded from the denominator** |
| kills | proven equivalent | `EQGAP` | contradiction — the suite "detected" a mutant that provably cannot differ, indicating a non-deterministic or wrongly specified testbench rather than a coverage win |

Corrected coverage = `COVERED / (COVERED + UNCOVERED)`.

The `EQGAP` quadrant is itself a disclosed diagnostic: a non-empty `EQGAP`
population is evidence of testbench non-determinism or over-specification,
detectable by no other means in this flow.

### 1.5 Cross-layer single-point verification detection

A further disclosed use of the surviving-mutant population: a mutant that
survives the corpus **and** is proven non-equivalent identifies input
subspaces that no verification layer exercises. Where the surviving mutants
cluster in a single property's logic, they reveal that the property is
verified at a *point* rather than over a *range*, and — importantly — this
can hold simultaneously across independent verification layers that were
believed to provide independent assurance.

Worked instance, from the reference implementation: mutants in a
canonical-range rejection path survived because the only out-of-range
operand value presented anywhere was the modulus `q` itself — the corpus
generator derived its invalid cases from `q`, and the separate formal
fail-closed harness drove a fixed request equal to `q`. A mutant accepting
`q + 2048` instead of faulting was therefore invisible to simulation and to
the formal proof at once. Neither layer could have revealed this alone;
the mutation-plus-equivalence method did.

### 1.6 Reference implementation and known prior art

Implemented at `verification/mutation/` in this repository, with per-mutant
analysis at `docs/MUTATION_ANALYSIS.md`. Measured result: corrected
coverage 96.32% (183/190) with 10 mutants proven equivalent and excluded,
against a raw uncorrected ratio of 91.50% (183/200).

Known prior art, disclosed for accuracy: formal classification and
pre-simulation elimination of non-propagatable **stuck-at faults** is
covered by the OneSpin/Siemens EDA family (US 11,816,410 B2, US 11,520,963
B2, US 2018/0364298 A1; priority 2017-06-19) and is marketed in Cadence's
Jasper FSV App. Netlist mutation with coverage measurement, without
equivalence filtering, appears in IBM US 9,443,044 B2 (priority
2013-10-24). Mutation-based functional qualification without equivalence
exclusion appears in the Synopsys Certitude family (US 8,997,034 B2). The
software analogue of excluding equivalent mutants via compiler equivalence
is Papadakis et al., "Trivial Compiler Equivalence", ICSE 2015.

The delta disclosed here, and placed in the public domain, is the
combination of netlist mutation, differential corpus replay, and a
**two-engine reachability-aware-plus-inductive equivalence oracle** used to
correct the coverage denominator, together with the four-way
classification, the conservative `UNKNOWN` treatment, and the cross-layer
single-point detection use in §1.5.

---

## 2. Cross-algorithm device identity succession with registry continuity

### 2.1 Problem

Secure elements used for device identity in long-lived infrastructure
commonly fuse the identity keypair at manufacture. A published example:
the Microchip ECC608-TNGHNT datasheet states its identity key "will be
generated by Microchip at the time of provisioning and will be permanently
locked". Devices with a service life measured in decades therefore carry a
classical (ECDSA P-256) identity that cannot be rotated, and no migration
path to post-quantum identity exists in the deployed networks surveyed.

### 2.2 Disclosed method

A device-identity scheme in which the identity is a **verifiable succession
chain** rather than a fused key:

1. The device holds an identity key in a secure element and is registered
   in a registry (a certificate authority, a network onboarding registry,
   or an append-only public ledger) under an identifier bound to that key.
2. To migrate algorithm family (e.g. ECDSA P-256 → ML-DSA-65), the secure
   element generates a successor keypair internally, non-exportably, of the
   new algorithm family.
3. The device produces a **succession assertion** binding: the registry
   identifier, the old public key, the new public key, the new algorithm
   identifier, and a monotonic succession counter — signed **by the old
   private key**, and additionally self-signed by the new private key to
   prove possession of both.
4. The registry verifies both signatures, checks the succession counter
   strictly increases, and updates the binding while retaining the prior
   binding as history, so that a relying party which never observed the
   device can verify the current key is the legitimate successor of the
   originally certified key by walking the chain.
5. The scheme resists an operator that controls the device but not the old
   private key: without a signature from the old key, no succession
   assertion verifies, so a substituted device cannot inherit an identity.

### 2.3 Known prior art

This concept is substantially anticipated and is published here only to
prevent narrower variants being removed from the public domain. NXP
US 2025/0300812 A1 ("Cryptographic agility", priority 2024-03-21) discloses
authenticated in-field algorithm replacement motivated by ECC/RSA-to-PQC
transition, and its claim 8 discloses generating a new device keypair and
certifying it under a one-time signature key. Qualcomm EP 1969762 B1
(priority 2005) discloses signing a second public key with the first
private key to obtain a signed certificate. IEEE 802.1AR (IDevID/LDevID)
standardises a permanent manufacturer identity anchoring re-keyable local
identities. TCG TPM 2.0 `TPM2_Certify` provides key-certifies-key
attestation.

The delta disclosed here is the combination of cross-algorithm-family
succession, dual-signature proof of possession, a monotonic succession
counter, and retained succession history in an append-only registry
permitting third-party verification without prior observation of the
device.

---

## 3. Provenance-binding signer with exclusive peripheral control

### 3.1 Disclosed method

A signing element that holds a key and has **exclusive hardware control**
of a sensing peripheral (radio receiver, GNSS receiver, sensor bus), such
that the key can sign only structured messages originating from that
peripheral. A host processor, even if fully compromised, cannot induce the
element to sign attacker-supplied data, because the element accepts no
externally-supplied message body for the sensor-signing operation. Any
non-sensor signing operation the element offers uses a **distinct
domain-separation prefix** in the signed message, so a signature over
non-sensor data can never be replayed as a sensor observation. Signed
records carry structured, versioned fields (measurement, timestamp,
position, receiver metadata) rather than opaque bytes.

### 3.2 Known prior art

**This concept is anticipated in full** by Helium HIP-72 "Secure
Concentrators", published to a public repository on 2022-10-12, which
discloses exclusive radio control by a secure processor, refusal to sign
arbitrary data, and a `nonrf` domain-separation prefix. Related art
includes Microsoft US 8,832,461 B2 (trusted sensors), Oracle
US 12,216,769 B2 (secure element with exclusive peripheral control), and
Gen Digital US 11,128,473 B1 (signing sensor data before host exposure).

It is restated here so that the post-quantum variant — the same
architecture with a lattice signature scheme and the rotatable identity of
§2 — is unambiguously in the public domain.

---

## 4. Key-provenance attestation at registry onboarding

### 4.1 Disclosed method

At onboarding, a device submits its identity public key together with an
**internally generated attestation** proving that the key was generated
inside, and is non-exportable from, a genuine certified secure element —
using the element's internal-sign capability, which signs only
element-generated statements about its own key slots and configuration.
The registry verifies the attestation against the element vendor's
certificate chain *before* binding the key to an identity, so that a
manufacturer cannot register a key held in software or extracted from
hardware.

### 4.2 Known prior art

**Anticipated.** The mechanism is documented in the Microchip ATECC508A
datasheet (Sign(Internal): "permits a remote entity to have the knowledge
that a particular key value or slot contents are stored within an
ATECC508A device"). System-level combinations with registrar verification
and ledger registration appear in Rivetz US 2016/0275461 A1 (priority
2015-03-20) and DigiCert/Mocana US 11,403,402 B2 (priority 2017-11-30).
Android Key Attestation, IEEE 802.1AR and TPM EK credentials cover the
same ground. Published here for completeness of the record.

---

## 5. Versioned machine-readable power-behaviour contract

### 5.1 Disclosed method

A hardware IP block publishes a **versioned, schema-defined, machine-
readable time-domain activity/power profile** as a design contract
consumed by downstream power-converter, regulator, decoupling and thermal
tooling, in place of a single thermal-design-power figure. The profile
records per-sample time, activity state (idle / operation-class / fault /
zeroize), clock and voltage operating point, and either estimated or
measured power, with mandatory provenance metadata distinguishing
simulator-derived, post-synthesis-estimated, and instrument-measured
sources so that a consumer can never mistake an estimate for a measurement.
A generator derives the profile from simulation activity, and the same
schema carries later measured data, so the contract is stable across the
project lifecycle.

### 5.2 Known prior art

**Anticipated.** Apache Design / Ansys Chip Power Model v2.0
(announced 2011-01-31) provides time-domain switching-current profiles with
decap models consumed downstream for package and decoupling optimisation.
IEC 62433-2 (ICEM-CE, 2008; Ed.2 2017) standardises an Internal Activity
time-domain profile with an XML exchange schema (CEML). IEEE 2416-2019
covers parameterized system and IP power models. Cadence US 8,656,329 B1
(priority 2010) covers automated regulator and decoupling analysis from a
behavioural core-current model.

Published here so that the specific variant implemented in this repository
— schema at `spec/power-trace.schema.json`, generator at
`tools/power_trace_from_vcd.py`, with mandatory estimate-versus-measurement
provenance — remains freely practicable.

---

## 6. What this document does not do

- It does not grant rights in third-party patents listed as prior art.
  Practising §2 may still require a licence from NXP or others; the
  disclosure prevents *new* patents on the disclosed delta, it does not
  clear existing ones.
- It does not alter the repository's Apache-2.0 licence or its patent
  grant.
- It does not assert that any concept here is novel. Sections 3, 4 and 5
  are expressly identified as anticipated.
- It is not a legal instrument. Its effect is that of a dated public
  technical disclosure.
