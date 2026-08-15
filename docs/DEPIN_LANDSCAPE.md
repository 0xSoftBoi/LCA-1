# DePIN landscape and market assessment

Surveyed August 2026 from primary sources only — official documentation
sites, governance proposals (HIPs/DIPs/DLPs), vendor datasheets, and project
source code. Third-party articles were used only where explicitly marked.
Every claim below carries a source; anything the primary docs do not state is
marked UNVERIFIED, and in several cases that silence is itself the finding.

This document exists because LCA-1's parent program targets a bridge and
chain-attached appliance, which places it in the decentralized physical
infrastructure (DePIN) category. The honest conclusion of this survey is
**negative for the obvious market and positive for a narrower one**, and this
repository records that rather than the more flattering version. Nothing here
is a product claim; `spec/ACCEPTANCE.md` still gates every claim we make.

## Summary of findings

1. **No DePIN network uses post-quantum cryptography anywhere.** Verified by
   reading docs and by code search across the Helium, peaq, DIMO, WeatherXM,
   Phala, and io.net GitHub organizations: zero references to ML-KEM, ML-DSA,
   FIPS 203/204/205, Kyber, Dilithium, or SPHINCS+. The sector is uniformly
   P-256, secp256k1, and Ed25519.
2. **Millions of DePIN devices carry permanently frozen classical keys.**
   This is the strongest genuine argument in the survey and it is a *problem
   statement*, not a sales pitch — see §3.
3. **The blockchain space is converging away from ML-DSA**, toward hash-based
   signatures for consensus and Falcon for compact account signatures (§5).
4. **Demand evidence for hardware PQC acceleration is directly negative**,
   not merely absent (§5) — one network closed a PQC proposal explicitly for
   lack of demand.
5. **Maker programs, the assumed channel, are decaying** (§7).
6. **The genuine technical gap is data provenance, not key possession** (§4),
   and the one proposal that tried to close it was rejected by token vote.

## 1. Method and scope

Four independent surveys were run: device identity and secure elements;
confidential-compute attestation; hardware maker programs; and post-quantum
posture across chains and DePIN networks. Where documentation was vague,
source code and datasheets were read directly. This document reports what the
primary sources say, including where they contradict their own marketing.

## 2. The DePIN device-identity pattern

Every network with real device identity converges on the same five stages:

1. **The manufacturer is the root of trust — not the silicon.** An
   allowlisted, KYC'd maker is granted the exclusive right to introduce
   devices (Helium's Onboarding Oracle; DIMO's Manufacturer NFT with
   `MANUFACTURER_MINTER_PRIVILEGE`). Admission is governance and legal, not
   cryptographic.
2. **A device keypair is created at manufacture and its public half is handed
   to a registry over an out-of-band channel.**
3. **The on-chain object is an NFT bound to that public key** (Helium
   compressed NFT + `KeyToAssetV0`; DIMO `AftermarketDevice` ERC-721; IoTeX
   ERC-721 + ERC-6551 machine-bound account; peaq Machine NFT).
4. **Owner claiming is a co-signature ceremony where it exists at all.** DIMO
   is the strongest: `claimAftermarketDeviceSign` verifies EIP-712 signatures
   from *both* owner and device. WeatherXM and GEODNET degrade this to a
   printed bearer secret, which proves proximity to a sticker.
5. **Ongoing data trust is bought with statistics and money, not hardware** —
   token-burn Sybil costs plus denylists, trust scores, quality-of-data
   scoring, and vision consensus.

### Secure elements actually deployed

| Network | Documented part | Algorithm | Key exportable |
|---|---|---|---|
| Helium (Trust&GO) | [Microchip ECC608-TNGHNT](https://ww1.microchip.com/downloads/aemDocuments/documents/SCBU/ProductDocuments/DataSheets/ECC608-Trust-and-GO-For-Helium-Network-Data-Sheet-DS40002389.pdf) | ECDSA P-256, compact pubkey | No — "can never be read" |
| Helium (default fallback) | **none — key file on disk** | Ed25519 software | **Yes** |
| WeatherXM D1/M5 | ATECC608 (variant undisclosed) | P-256 implied, never stated | UNVERIFIED |
| DIMO Macaron | NXP SE050 | secp256k1, EIP-712 | UNVERIFIED |
| DIMO AutoPi / Ruptela | "a secure element", part undisclosed | secp256k1 | UNVERIFIED |
| IoTeX ioID SDK | **none** — PSA storage in ESP32 flash | P-256 / Ed25519 | **Yes** |
| peaq (peaqOS 2026) | **none** — "Verify … coming soon" | secp256k1 | **Yes** |
| Hivemapper, GEODNET, Silencio | none documented | none documented | n/a |

Two observations that matter more than the parts list. First, Helium's
secure element is **optional in its own tooling**: `gateway-mfr-rs` falls back
to a software Ed25519 key written to disk when no backend URL is given, and
`gateway-rs` documents the ECC path as opt-in configuration. Second, the
security requirement in [HIP-19](https://github.com/helium/HIP/blob/main/0019-third-party-manufacturers.md)
is disjunctive — "either via disk encryption **or** hardware measures like an
ECC chip" — and data-only hotspots are exempt entirely.

## 3. The frozen-key finding

The ECC608-TNGHNT datasheet states that the Helium identity key is
"generated by Microchip at the time of provisioning and will be **permanently
locked**." The part does provide two secondary P-256 slots that the user can
regenerate; **Helium's provisioning uses neither.**

The consequence is precise and checkable: DePIN has deployed a large
installed base of roof-mounted, vehicle-mounted, and field infrastructure —
hardware with a decade-plus service life — carrying **classical P-256
identity keys that cannot be rotated**, with no migration path documented in
any published roadmap across any network surveyed.

This is a genuine, dated, structural problem, and it is the strongest honest
argument this survey found for post-quantum-capable device silicon. Three
caveats keep it from being a business case on its own:

- it is an argument for **crypto-agility and rotatable key hierarchies**
  first, and for post-quantum algorithms second;
- the installed base cannot be retrofitted — it addresses *future* device
  generations only;
- no network has stated it considers this a problem, which means the demand
  is latent, not expressed (§5).

## 4. Possession is not provenance

The most important architectural sentence found in the survey is Helium's
own, from [HIP-72](https://github.com/helium/HIP/blob/main/0072-secure-concentrators.md):

> "Anyone can modify the software running on a Hotspot and generate fake LoRa
> packets. This is a big problem because PoC rewards are based on these
> packets."

and, on why a conventional secure element does not fix it:

> "If the SMCU's firmware allowed for signing arbitrary data with its Hardware
> Key, an attacker could jailbreak the Host CPU and craft a signing request
> that contained fake RF data."

A general-purpose secure element proves *"I possess key K"* and never *"this
sensor reading is real."* The ECC608-TNGHNT's identity slot is documented as
able to sign external messages, so a compromised host simply asks the chip to
sign fabricated data.

HIP-72 diagnosed this correctly and proposed the fix — a secure MCU with
exclusive control of the radio bus, permitted to sign only radio-originated
structured data, with a `nonrf` domain-separation prefix for everything else,
plus open hardware and GPLv3 firmware and a 1.25× reward multiplier. **The
network rejected it.**

The same architectural break is visible elsewhere. WeatherXM claims data is
"cryptographically signed at the source," but its own FAQ places the crypto
chip and GPS in an *indoor* gateway for the Wi-Fi bundles, with the outdoor
sensor connected over a proprietary RF link — so the signature attests that a
gateway received some bytes, and the signed GPS fix locates the living room
rather than the anemometer. Hivemapper looked at the problem and
[explicitly chose not to rely on hardware](https://docs.hivemapper.com/honey-token/map-data-structure-and-verification/),
using vision consensus and device reputation instead.

**DePIN has a device-identity layer; it does not have a data-provenance
layer.** A further gap: the ECC608-TNGHNT ships a slot-1 internal-sign key
attestation that would prove a public key originated inside genuine silicon,
and Helium's onboarding does not use it — every network surveyed accepts a
bare public key over an out-of-band channel and takes the manufacturer's word
for where it lives.

## 5. Post-quantum posture — the blunt version

**In DePIN: nothing.** Confirmed by documentation review and organization-wide
code search. No network has PQC in docs, code, or on a roadmap. IoTeX is the
sole partial exception with genuine PQC research
([EIP-7693](https://ethereum-magicians.org/t/eip-7693-backward-compatible-post-quantum-migration/19769)),
and it proposes hash-based/zero-knowledge constructions, not lattices, and is
unmerged and undeployed.

**In the chains DePIN sits on, the direction of travel is away from ML-DSA:**

- Ethereum's consensus post-quantum program is **hash-based** — leanXMSS
  validator signatures and a hash-chain RANDAO, with aggregation via a
  zkVM rather than algebraic aggregation ([pq.ethereum.org](https://pq.ethereum.org/),
  [leanroadmap.org](https://leanroadmap.org/)). Execution-layer PQC is Draft
  only, and its two ML-DSA proposals target **ML-DSA-44**, not 65.
- **Algorand shipped Falcon** (state proofs since 2022; Falcon-1024 logic-sig
  accounts November 2025). Anza and Firedancer both built Falcon
  independently. Signature size drives these decisions: every byte is
  replicated to every node forever, and ML-DSA-65's 3,309-byte signature
  loses badly to Falcon-512's ~666.
- **Bitcoin's BIP-360 removed post-quantum signatures** in v0.8.0 (July 2025);
  BIP-361 defines a migration schedule naming no scheme.
- **Cosmos SDK v0.55 (28 July 2026) shipped native `ml_dsa_65`** — exactly
  LCA-1's parameter set, for both validator and account keys. This is the one
  genuinely favourable datapoint, and the same documentation says signing and
  verification are "slightly slower than with ed25519" and this "is unlikely
  to affect most chains," identifying **bandwidth and state growth (~1.8 TB
  per year) as the real cost** — which no accelerator addresses.

**Demand evidence is directly negative:**

- Solana **closed** SIMD-0461 (a Falcon verification syscall) in June 2026,
  because a software implementation already verifies in under 170k compute
  units and reviewers "questioned whether genuine external demand existed."
- The Solana Foundation states "no change is required today or likely anytime
  soon."
- Cloudflare deployed ML-KEM to **over half of human web traffic with no
  hardware changes**, and its published benchmarks put ML-KEM-768 at
  31,000–70,000 ops/s against X25519's 17,000 — post-quantum key agreement is
  already *faster* than the classical primitive it replaces on a commodity
  core.

**In confidential compute, PQC cannot reach the root at all.** Intel TDX
quotes are signed by Intel's provisioning infrastructure, AWS Nitro documents
chain to the AWS Nitro root certificate, and GPU evidence chains to NVIDIA's
root CA. Those algorithms are chosen by the silicon vendors and are classical
ECDSA P-256. **Any claim of a "post-quantum attested" appliance is false at
the root** while a vendor quote is in the chain. Equally, PQC mitigates none
of the threats these systems actually document — Spectre, Meltdown,
Foreshadow, ÆPIC, SEVered, and access-pattern leakage are not discrete-log
problems.

### Parameter-set fork

LCA-1 implements the arithmetic for **ML-KEM-768 / ML-DSA-65**. CNSA 2.0
mandates **ML-KEM-1024 / ML-DSA-87** at all classification levels, with new
national-security-system acquisitions required to support it from 1 January
2027. The commercial story (TLS hybrid X25519MLKEM768, Cosmos `ml_dsa_65`)
and the government story (CNSA 2.0) therefore **require different parameter
sets**. The moduli are shared across all parameter sets, so the arithmetic
layer is compatible with both — but a product claim is not, and the program
should choose explicitly rather than implying both.

## 6. Workload arithmetic — where acceleration could matter

Using the authenticated bridge operation defined in `spec/WORKLOAD.md`
(1 encapsulation, 1 decapsulation, 2 signatures, 2 verifications) and the
optimized Cortex-M4 cycle counts published by
[pqm4](https://github.com/mupq/pqm4/blob/master/benchmarks.md):

| Device class | Cost of one authenticated bridge operation |
|---|---|
| Cortex-M4 @ 64 MHz | ~290 ms |
| Cortex-M4 @ 100 MHz | ~186 ms |
| Cortex-M4 @ 168 MHz | ~111 ms |
| Server core @ 3 GHz (same cycle counts) | ~6 ms |

Total is 18,584,811 cycles. Independent confirmation of the order of
magnitude comes from wolfSSL's STM32 measurements (ML-DSA-65 sign 84 ms,
verify 36.7 ms at 168 MHz), which are slower than pqm4's hand-optimized
assembly — the honest range is therefore roughly 100–400 ms on this device
class.

The reading is unambiguous in both directions. **On server-class hardware,
software is over-provisioned by three to four orders of magnitude** against
real transaction rates — a Cosmos chain with 100 validators performs about 17
verifications per second, and Ethereum settles ~15 transactions per second.
Positioning LCA-1 as a bridge or server throughput accelerator is
indefensible to anyone who checks. **On the MCU class that DePIN devices
actually ship, hundreds of milliseconds per operation is a real cost** in
latency, duty cycle, and battery. That is the only place the numbers support
an acceleration argument, and it argues for low-power device-side IP rather
than a server-side appliance.

## 7. Commercial reality: the maker channel is decaying

- **Helium.** The entire `/hotspot-makers/` documentation tree returns 404 in
  2026 and the application repository has been idle since June 2023. Fees,
  when the program was live: $1,000 application, $2,000 KYC, and a hardware
  audit at **$5,000 using an ECC608 versus $7,000 for another security
  implementation** — a quantified $2,000 penalty for novel silicon. Every
  governance attempt to raise the hardware-security bar or modernize the
  program (HIP-72, HIP-99, HIP-115) was rejected or closed. Meanwhile
  data-only onboarding fell to **$0.50** and enterprise Wi-Fi access points
  convert for **$2.00**, permissionless, with no secure element.
- **WeatherXM.** Charges **$100 per station manufactured** to the Association
  and publishes the most LCA-1-relevant specification found anywhere — secure
  element in two-way binding with the MCU, ECDSA or EdDSA keys provisioned at
  manufacture, "the private key must be generated and stored securely within
  the secure element in such a way that it is inaccessible to manufacturers,
  WeatherXM, or any third parties," signed measurements plus GNSS and
  metadata, and tamper-proof MCU-to-secure-element lines. But the approval
  process is still written in the future tense, the only manufacturers are
  founder-affiliated, and the Hardware Class Weight that could pay a premium
  for better hardware is **currently equal across all classes** — there is no
  yield to fund a bill-of-materials upgrade.
- **DIMO.** The best-designed governance artifact — a real PKI with
  Manufacturer Root certificates issuing Device Minting Certificates, and
  third-party security audits — but the hardware documentation tree is
  entirely 404, the program licensed roughly four hardware entities in its
  lifetime, and the product has pivoted to a phone app and a vehicle-data API.
- **peaq and IoTeX** impose no hardware requirements at all, so they are free
  integration targets that confer no differentiation. peaq is candid that its
  hardware-signed trust level is self-attested: "there's no third-party
  attestation infrastructure behind it yet."

**No DePIN network documents export-control considerations.** For a
cryptographic coprocessor that burden lands entirely on us.

## 8. Attestation patterns worth reusing

Independent of the market question, the confidential-compute projects have
converged on patterns that a composed appliance boundary should adopt rather
than reinvent:

1. **Layered measurement registers with an explicit per-register contract.**
   Phala and Secret Network independently converged on the same Intel TDX
   layout (firmware, virtual hardware, kernel, command line and initrd, then
   application identity). Publish which register covers which component and
   never let one register cover two.
2. **Nonce-in-report-data challenge-response, verified strictly outside the
   enclave.** Universal across projects.
3. **Bind the transport key into the quote.** An attestation not bound to the
   channel is worthless because it can be relayed.
4. **Attestation-gated key release, with policy on-chain and quote parsing
   off-chain.** Nobody parses a full DCAP quote in a smart contract in
   production; the chain stores the allowlist and a measured verifier does
   the cryptography.
5. **Verifier-enclave chain of trust** (Marlin): verify one enclave on-chain,
   have it issue signed receipts, and every other verification becomes a
   cheap signature check.
6. **Reproducible builds as a mandatory companion.** Measurements are only
   meaningful against a reproducible artifact — a natural strength for an
   open-source design and a weakness for closed accelerators.
7. **Structured claims carrying status *and* provenance.** Phala tags each
   claim `hardware_proven`, `verifier_derived`, `provider_asserted`, or
   `operator_asserted`. This is exactly the vocabulary a composed boundary
   needs to avoid overclaiming, and it maps directly onto the layered
   responsibility table in `GOAL.md`.

**Documentation honesty is an uncrowded frontier.** Phala publishes "TEEs can
be compromised," an explicit residual-risk section, and its own High-severity
audit finding. Secret Network's live documentation still describes SGX attacks
as "often theoretical, executed in laboratory settings" on a page last updated
three years ago — while researchers extracted that network's consensus seed in
2022 via the ÆPIC/MMIO vulnerabilities, which would have retroactively
decrypted every private transaction since genesis. The incident is documented
externally and absent from their docs. What saved them was that microcode
level was an enforced admission predicate, which is an argument for
attestation-gated re-admission as a design requirement.

## 9. Where LCA-1 honestly fits

**Non-claims, stated first.** Nothing in this survey supports claiming that
LCA-1 accelerates bridges or chains meaningfully (§6), hardens a TEE (§5),
makes an attested appliance post-quantum at the root (§5), meets CNSA 2.0
(§5), or has an identified DePIN customer (§5, §7). This document exists in
part so that none of those claims are made later by accident.

**What the evidence does support, as hypotheses to be tested rather than
positions to be asserted:**

1. **A latent crypto-agility problem exists and is documented** (§3).
   Non-rotatable classical keys in decade-lifetime infrastructure is a real
   structural defect, and no network has a migration path.
2. **The data-provenance gap is real, correctly diagnosed by the industry
   itself, and unsolved** (§4). The requirement HIP-72 specified — a signer
   with exclusive control of a sensing peripheral, permitted to sign only
   structured domain-separated data — is a hardware requirement, not a
   software one. Note the cautionary half: HIP-72 was open-source, technically
   superior, grant-backed, and **still voted down**.
3. **The device-side workload numbers support device-side acceleration**
   (§6), which points at low-power IP rather than the appliance.
4. **The strongest PQC insertion points are above the hardware root**: the
   client-to-enclave channel (harvest-now-decrypt-later against recorded
   traffic), long-lived seeds whose compromise is retroactive, the receipt
   and verifier layer, and governance and policy signing. All four are under
   an operator's control and require no vendor cooperation.
5. **Open, auditable crypto silicon does not exist in this sector.** Every
   deployed secure element is closed proprietary IP, and the one open effort
   was rejected. Whether that absence is an opportunity or a revealed
   preference is genuinely open — §7 suggests the latter is currently
   winning.

**Governance is both the chokepoint and the lever.** Chip selection in DePIN
is set top-down by certification documents: HIP-19 named the ECC608 and makers
followed; DIMO's DIP-4 mandated a secure element and every licensee complied.
The route into this market is therefore an amendment to a certification
document naming a post-quantum-capable, attestation-capable option — the same
route HIP-72 took and lost.

## 10. Falsifiable triggers

This assessment should be revisited if any of the following becomes true.
Each is checkable, and each would move the conclusion:

- a major Cosmos chain activates `ml_dsa_65` in production, creating real
  ML-DSA-65 verification volume;
- any DePIN network publishes a PQC or crypto-agility requirement, or a
  key-rotation ceremony, in its certification documents;
- a network reinstates a hardware-security reward multiplier (the HIP-72
  1.25× mechanism, or WeatherXM un-pinning its Hardware Class Weight);
- Ethereum's execution-layer PQC settles on a lattice signature at ML-DSA-65
  rather than ML-DSA-44 or Falcon;
- CNSA 2.0's January 2027 procurement gate produces a government-adjacent
  DePIN or bridge deployment requiring ML-KEM-1024 / ML-DSA-87;
- a documented key-compromise incident affects a deployed DePIN fleet with
  non-rotatable keys.

## 11. Primary sources

Device identity: [Helium HIP-19](https://github.com/helium/HIP/blob/main/0019-third-party-manufacturers.md) ·
[HIP-72](https://github.com/helium/HIP/blob/main/0072-secure-concentrators.md) ·
[ECC608-TNGHNT datasheet DS40002389](https://ww1.microchip.com/downloads/aemDocuments/documents/SCBU/ProductDocuments/DataSheets/ECC608-Trust-and-GO-For-Helium-Network-Data-Sheet-DS40002389.pdf) ·
[gateway-mfr-rs](https://github.com/helium/gateway-mfr-rs) ·
[helium-crypto-rs](https://github.com/helium/helium-crypto-rs) ·
[WeatherXM docs](https://docs.weatherxm.com/) and [FAQ](https://docs.weatherxm.com/faq) ·
[WeatherXM third-party hardware spec](https://weatherxm.network/hw-specs-20240924.pdf) ·
[DIMO DIP-4 and DLPs](https://github.com/DIMO-Network/DIP) ·
[dimo-identity](https://github.com/DIMO-Network/dimo-identity) ·
[IoTeX ioID](https://docs.iotex.io/ioid/technical-specification/ioid-registry) ·
[ioID-SDK](https://github.com/iotexproject/ioID-SDK) ·
[peaqOS Verify](https://docs.peaq.xyz/peaqos/functions/verify) and
[trust levels](https://docs.peaq.xyz/peaqos/concepts/trust-levels) ·
[Hivemapper verification](https://docs.hivemapper.com/honey-token/map-data-structure-and-verification/)

Confidential compute: [Phala chain of trust](https://docs.phala.com/phala-cloud/attestation/chain-of-trust.md) ·
[Phala claims model](https://docs.phala.com/phala-cloud/confidential-ai/confidential-model/tcb-and-claims.md) ·
[Phala security model](https://docs.phala.com/dstack-cloud/security-model.md) ·
[Oasis Sapphire concepts](https://docs.oasis.io/build/sapphire/develop/concept/) ·
[Super Protocol TEE requirements](https://docs.superprotocol.com/fundamentals/gpu-cpu-tee-requirements) ·
[Marlin remote attestations](https://docs.marlin.org/oyster/core-concepts/remote-attestations) ·
[Marlin attestation verifier](https://docs.marlin.org/oyster/build-cvm/examples/attestation-verifier) ·
[io.net confidential compute](https://io.net/docs/guides/clouds/confidential-compute-attestation-overview.md) ·
[Secret Network SecretVM attestation](https://docs.scrt.network/secret-network-documentation/secretvm-confidential-virtual-machines/attestation/what-is-attestation) ·
[sgx.fail](https://sgx.fail/)

Post-quantum posture: [pq.ethereum.org](https://pq.ethereum.org/) ·
[leanroadmap.org](https://leanroadmap.org/) ·
[Cosmos post-quantum keys](https://github.com/cosmos/docs/blob/main/sdk/latest/keys/post-quantum-keys.mdx) ·
[Solana quantum readiness](https://solana.com/news/quantum-readiness) ·
[SIMD-0461](https://github.com/solana-foundation/solana-improvement-documents/pull/461) ·
[Algorand post-quantum](https://algorand.co/technology/post-quantum) ·
[BIP-360](https://github.com/bitcoin/bips/blob/master/bip-0360.mediawiki) ·
[Cloudflare PQ 2025](https://blog.cloudflare.com/pq-2025/) ·
[CNSA 2.0 FAQ](https://media.defense.gov/2022/Sep/07/2003071836/-1/-1/0/CSI_CNSA_2.0_FAQ_.PDF) ·
[NIST IR 8547 ipd](https://csrc.nist.gov/pubs/ir/8547/ipd)

Workload: [pqm4 benchmarks](https://github.com/mupq/pqm4/blob/master/benchmarks.md) ·
[wolfSSL STM32 PQ benchmarks](https://www.wolfssl.com/updated-post-quantum-benchmarks-for-ml-kem-and-ml-dsa-on-stm32/)
