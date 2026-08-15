# References

Normative standards, algorithm literature, implementation baselines, and
tooling that the LCA-1 specifications and implementation build on. Citations
here back the design decisions recorded in `spec/`; a claim in this repository
that depends on external work should trace to an entry below.

## Normative standards

1. National Institute of Standards and Technology. *Module-Lattice-Based
   Key-Encapsulation Mechanism Standard*. FIPS 203, August 2024.
   <https://doi.org/10.6028/NIST.FIPS.203>
2. National Institute of Standards and Technology. *Module-Lattice-Based
   Digital Signature Standard*. FIPS 204, August 2024.
   <https://doi.org/10.6028/NIST.FIPS.204>
3. National Institute of Standards and Technology. *SHA-3 Standard:
   Permutation-Based Hash and Extendable-Output Functions*. FIPS 202,
   August 2015. <https://doi.org/10.6028/NIST.FIPS.202>
4. National Institute of Standards and Technology. *Security Requirements for
   Cryptographic Modules*. FIPS 140-3, March 2019.
   <https://doi.org/10.6028/NIST.FIPS.140-3>
   (Referenced as an explicit non-claim: no LCA-1 artifact is validated.)

## Underlying algorithm designs

5. J. Bos, L. Ducas, E. Kiltz, T. Lepoint, V. Lyubashevsky, J. M. Schanck,
   P. Schwabe, G. Seiler, and D. Stehlé. "CRYSTALS – Kyber: A CCA-Secure
   Module-Lattice-Based KEM." *IEEE European Symposium on Security and
   Privacy (EuroS&P)*, 2018. <https://doi.org/10.1109/EuroSP.2018.00032>
6. L. Ducas, E. Kiltz, T. Lepoint, V. Lyubashevsky, P. Schwabe, G. Seiler,
   and D. Stehlé. "CRYSTALS-Dilithium: A Lattice-Based Digital Signature
   Scheme." *IACR Transactions on Cryptographic Hardware and Embedded
   Systems*, 2018(1), 2018. <https://doi.org/10.13154/tches.v2018.i1.238-268>
7. G. Bertoni, J. Daemen, M. Peeters, and G. Van Assche. "The Keccak
   Reference," version 3.0, 2011. <https://keccak.team/files/Keccak-reference-3.0.pdf>

## Arithmetic foundations

8. J. W. Cooley and J. W. Tukey. "An Algorithm for the Machine Calculation of
   Complex Fourier Series." *Mathematics of Computation*, 19(90):297–301,
   1965. <https://doi.org/10.1090/S0025-5718-1965-0178586-1>
9. W. M. Gentleman and G. Sande. "Fast Fourier Transforms — for Fun and
   Profit." *AFIPS Fall Joint Computer Conference*, pp. 563–578, 1966.
   <https://doi.org/10.1145/1464291.1464352>
10. P. L. Montgomery. "Modular Multiplication Without Trial Division."
    *Mathematics of Computation*, 44(170):519–521, 1985.
    <https://doi.org/10.1090/S0025-5718-1985-0777282-X>
11. P. Barrett. "Implementing the Rivest Shamir and Adleman Public Key
    Encryption Algorithm on a Standard Digital Signal Processor." *Advances in
    Cryptology — CRYPTO '86*, LNCS 263, 1987.
    <https://doi.org/10.1007/3-540-47721-7_24>
12. P. Longa and M. Naehrig. "Speeding up the Number Theoretic Transform for
    Faster Ideal Lattice-Based Cryptography." *Cryptology and Network
    Security (CANS)*, LNCS 10052, pp. 124–139, 2016.
    <https://doi.org/10.1007/978-3-319-48965-0_8>

## Side-channel adversary model

13. P. C. Kocher. "Timing Attacks on Implementations of Diffie-Hellman, RSA,
    DSS, and Other Systems." *CRYPTO '96*, LNCS 1109, 1996.
    <https://doi.org/10.1007/3-540-68697-5_9>
14. P. Kocher, J. Jaffe, and B. Jun. "Differential Power Analysis."
    *CRYPTO '99*, LNCS 1666, 1999. <https://doi.org/10.1007/3-540-48405-1_25>
    (Motivates the constant-iteration multiplier requirement and the
    power-trace contract; masking and physical resistance remain explicit
    non-claims — see `spec/THREAT_MODEL.md`.)

## Implementation and verification baselines

15. M. J. Kannwischer, P. Schwabe, D. Stebila, and T. Wiggers. "Improving
    Software Quality in Cryptography Standardization Projects." *IEEE European
    Symposium on Security and Privacy Workshops (EuroS&PW)*, 2022.
    <https://doi.org/10.1109/EuroSPW55150.2022.00010> (the PQClean project,
    pinned in `third_party/PQClean` as the differential-test oracle)
16. lowRISC contributors. *OpenTitan: Open Source Silicon Root of Trust*.
    <https://opentitan.org> (evidence that open RTL plus commercial-grade
    verification can reach production secure silicon; see `GOAL.md`)
17. CHIPS Alliance. *Caliptra: Datacenter Root of Trust*.
    <https://github.com/chipsalliance/caliptra-rtl>

## Tooling and process

18. C. Wolf. *Yosys Open SYnthesis Suite*. <https://yosyshq.net/yosys/>
    (lockfile-pinned WebAssembly build used for formal proofs and generic
    synthesis; exact version recorded in `package-lock.json`)
19. S. Williams. *Icarus Verilog*. <https://steveicarus.github.io/iverilog/>
    (event-driven simulator for the generated regression)
20. SkyWater Technology and Google. *SKY130 Open Source PDK*.
    <https://github.com/google/skywater-pdk> (target process for the Rev-A
    OpenFrame route; see `docs/FABRICATION_AND_PACKAGE.md`)
21. YosysHQ. *PicoRV32: A Size-Optimized RISC-V CPU*.
    <https://github.com/YosysHQ/picorv32> (pinned submodule; removed from the
    Rev-A accelerator-only cut — see `docs/REV_A_INTEGRATION.md`)

## Citing LCA-1

Cite the repository using the metadata in [`CITATION.cff`](../CITATION.cff)
(GitHub renders a "Cite this repository" entry from it). When citing specific
evidence — the regression corpus, formal scope, or fabrication contract —
pin the exact commit hash, since claims are bounded per commit.
