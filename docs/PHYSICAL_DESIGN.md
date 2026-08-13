# LCA-1 physical implementation plan

The full-chip product top is an FPGA/ASIC-class SoC, not a Tiny Tapeout-sized
macro. It requires 256 KiB of ROM, 512 KiB of secure SRAM, a 32-bit CPU, a
1,600-bit Keccak state, a 256×32 NTT scratchpad, host I/O, and platform security
logic. The small `tt_um_suwappu_lattice_accel` top remains a separate arithmetic
characterization vehicle.

## Recommended implementation sequence

1. **FPGA prototype.** Map ROM/SRAM to block RAM, integrate the APB and stream
   ports with a bridge-host test system, close timing, and repeat whole-command
   differential tests on real hardware.
2. **ASIC synthesis with abstract memories.** Replace the portable memory
   models with target-specific wrappers, characterize critical paths, and
   choose a clock target from reports rather than RTL cycle counts.
3. **Security architecture pass.** Add lifecycle/debug policy, secure ROM
   provisioning, TRNG/conditioning, tamper monitors, masking/fault strategy,
   scan controls, and key-erasure requirements before floorplanning.
4. **Floorplan and power plan.** Place memory macros around the CPU and
   accelerators, reserve routing for wide Keccak/NTT datapaths, and model
   simultaneous switching during permutation rounds.
5. **P&R and signoff.** Close timing, congestion, IR drop, EM, DRC, LVS,
   antenna, CDC/RDC, reset, and gate-level regressions across required corners.
6. **Characterization silicon.** Run functional, voltage/frequency, power/EM,
   fault, remanence, and zeroization measurements before any production key use.

## Hard-macro boundaries

| RTL block | implementation requirement |
| --- | --- |
| `firmware_rom` in `lca_chip_top` | immutable ROM/compiler macro with the verified image and lifecycle policy |
| `lca_secure_sram` | at least 512 KiB total capacity, byte writes, explicit scrub path, test/repair policy |
| optional NTT coefficient RAM | may replace coefficient flops/array after cycle-accurate verification |
| platform wrapper | pad ring, APB/stream protocol adaptation, PLL/clock, reset synchronizers, power domains |
| entropy source | conditioned output, health tests, startup policy, and failure signaling |

The portable secure SRAM has an asynchronous read. Many ASIC SRAM compilers are
synchronous. A synchronous macro requires a bus adapter and PicoRV32 wait state;
changing that timing requires rebuilding and rerunning the actual firmware, not
only block-level RTL tests.

## Likely critical paths

- A complete Keccak theta/rho/pi/chi/iota round is combinational between state
  registers. If it misses the target, split each logical round across two
  clocks and update the firmware-visible busy latency without changing state
  semantics.
- NTT butterflies include signed multiplication and Montgomery/Barrett
  reduction. Technology mapping should decide whether these use DSPs,
  hard multipliers, or pipelined standard-cell arithmetic.
- The inferred 256×32 coefficient array may be flattened by generic synthesis.
  Use a true dual-port or one-read/one-write macro architecture before final
  area conclusions.
- Host DMA and CPU SRAM arbitration is combinational. Insert registered
  protocol stages if required, preserving CPU `mem_ready` behavior.
- The zeroize address counter and write path must reach every physical SRAM
  bank, including repair/spare structures and any additional cache or register
  file introduced by the platform.

## Clock, reset, and power

The portable top has one clock and active-low reset. A production wrapper must:

- synchronize reset deassertion and external tamper signals;
- define behavior for clock loss or glitch during zeroization;
- ensure the CPU cannot leave reset before SRAM/ROM/power are valid;
- isolate or clear outputs when the secure domain is unpowered;
- constrain and verify every generated/test clock and reset crossing;
- decide whether retention is forbidden for the secure SRAM domain.

Clock gating can reduce idle power but must not create secret-dependent gating
or prevent tamper zeroization. The current RTL intentionally makes no power or
frequency claim.

## Floorplanning notes

Keep the secure SRAM, CPU, NTT, and Keccak blocks in one controlled security
region with short, observable internal buses. Place the host frontend at the
periphery and cross into the security region through a narrow, registered
boundary. Separate the external entropy conditioner from deterministic host
inputs and avoid routing sensitive SRAM/NTT buses near untrusted high-toggle
I/O where practical.

Banking the 512 KiB SRAM can improve aspect ratio and routing. The scrub
controller must cover banks deterministically; the current single-word model
corresponds to 131,072 write clocks. A wider multi-bank scrub is allowed only
if its completion semantics and fault response are reverified.

## Signoff gates

| gate | required evidence |
| --- | --- |
| functional | whole-chip firmware simulation and FPGA differential commands pass |
| memory | macro timing/behavior matches bus adapter; BIST/repair/debug policy reviewed |
| synthesis | no unresolved cells/latches; intended RAM/ROM/multiplier inference confirmed |
| timing | setup/hold and recovery/removal close at all required corners and modes |
| physical | routed DRC/LVS/antenna, IR/EM, congestion, and clock reports pass |
| reset/CDC | structural and formal reset/clock-domain checks pass |
| post-layout | SDF/gate-level boot, self-test, decapsulation, verification, and zeroize pass |
| security | independent architecture/RTL/netlist review plus side-channel and fault campaigns |
| release | ROM image, source pins, reports, netlists, GDS, tests, and hashes archived together |

No gate count, area, frequency, power, or throughput number should be quoted as
a silicon result until it comes from the same routed artifact that passes these
gates. The cycle counts in the README describe only the current RTL control
schedule.

## Tiny arithmetic vehicle

The existing `src/config.json`, `info.yaml`, and Tiny Tapeout wrapper apply only
to the retained byte-wide arithmetic lane. They are not a floorplan for
`lca_chip_top`. Results from that shuttle can inform modular-arithmetic timing
and power, but they do not validate the CPU, memories, Keccak, full NTT, host
streams, firmware, or secret-handling boundary.
