# LCA-1 → VoltForge power contract

## Purpose

VoltForge should receive a time-domain load profile from LCA-1, not a single
marketing TDP. Converter, regulator, decoupling, cooling, and protection
decisions depend on idle-to-active steps, burst length, duty cycle, clock, and
fault/zeroization behavior.

The exchange format is defined by `spec/power-trace.schema.json` and the
dependency-free writer/integrator in `model/power_contract.py`.

## Required metadata

- trace source: simulator, post-synthesis estimate, board instrument, or lab instrument;
- hardware identity and revision;
- workload and parameter set;
- clock and voltage operating point;
- sample interval and instrument bandwidth for measurements;
- ambient and cooling condition;
- whether watts are estimated or measured;
- idle-power treatment and repetition count;
- source commit and tool versions.

## Activity states

`idle`, `kem`, `dsa`, `dma`, `zeroize`, and `fault` are the initial stable
states. Each sample records time, active lanes, clock, and either estimated or
measured watts. Future revisions may add rail-level voltage/current, but must
remain backward compatible.

## VoltForge use

VoltForge can transform the trace into:

- peak, average, and percentile power;
- idle→KEM and idle→DSA load-step slew;
- burst energy and required hold-up/decoupling;
- regulator efficiency over the actual duty-cycle distribution;
- thermal RC excitation and sustained temperature estimate;
- protection thresholds that do not trip on valid cryptographic bursts.

An estimated trace may guide exploration. Only a measured trace may support a
hardware efficiency claim, and VoltForge's own converter accuracy remains
gated on reference-design calibration.
