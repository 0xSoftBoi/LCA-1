// SPDX-License-Identifier: Apache-2.0
// STA-only blackboxes for the checksum-pinned SRAM22 macros.
//
// The upstream .v files are cycle-accurate behavioral simulation models and
// intentionally remain byte-identical to the pinned vendor source. OpenSTA
// requires a structural/blackbox Verilog declaration; timing arcs are supplied
// by the matching SRAM22 Liberty views, while LEF/GDS supply physical geometry.

`default_nettype none

/// sta-blackbox
module sram22_128x32m4w8 (
`ifdef USE_POWER_PINS
    inout wire vdd,
    inout wire vss,
`endif
    input  wire        clk,
    input  wire        rstb,
    input  wire        ce,
    input  wire        we,
    input  wire [3:0]  wmask,
    input  wire [6:0]  addr,
    input  wire [31:0] din,
    output wire [31:0] dout
);
endmodule

/// sta-blackbox
module sram22_2048x32m8w8 (
`ifdef USE_POWER_PINS
    inout wire vdd,
    inout wire vss,
`endif
    input  wire         clk,
    input  wire         rstb,
    input  wire         ce,
    input  wire         we,
    input  wire [3:0]   wmask,
    input  wire [10:0]  addr,
    input  wire [31:0]  din,
    output wire [31:0]  dout
);
endmodule

`default_nettype wire
