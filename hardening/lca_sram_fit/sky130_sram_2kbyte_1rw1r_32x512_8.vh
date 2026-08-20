// SPDX-License-Identifier: Apache-2.0
//
// Black-box declaration of the OpenRAM macro used by lca_sram_fit.
//
// The port list mirrors, one for one, the upstream Apache-2.0 behavioural
// model:
//   https://github.com/VLSIDA/sky130_sram_macros/blob/965df150c754fe2b3f93a0bd1f9883eb114279b2/sky130_sram_2kbyte_1rw1r_32x512_8/sky130_sram_2kbyte_1rw1r_32x512_8.v
// which declares "Words: 512 / Word size: 32 / Write size: 8", NUM_WMASKS = 4,
// DATA_WIDTH = 32 and ADDR_WIDTH = 9.
//
// Synthesis needs the interface only - the layout comes from the macro's LEF
// and GDS. For RTL simulation use the upstream behavioural .v instead of this
// header; nothing here models memory behaviour.

`ifndef SKY130_SRAM_2KBYTE_1RW1R_32X512_8_VH
`define SKY130_SRAM_2KBYTE_1RW1R_32X512_8_VH

(* blackbox *)
module sky130_sram_2kbyte_1rw1r_32x512_8 (
`ifdef USE_POWER_PINS
    inout  wire        vccd1,
    inout  wire        vssd1,
`endif
    // Port 0: read/write.
    input  wire        clk0,
    input  wire        csb0,   // active low chip select
    input  wire        web0,   // active low write enable
    input  wire [3:0]  wmask0, // byte write mask
    input  wire [8:0]  addr0,
    input  wire [31:0] din0,
    output wire [31:0] dout0,
    // Port 1: read only.
    input  wire        clk1,
    input  wire        csb1,   // active low chip select
    input  wire [8:0]  addr1,
    output wire [31:0] dout1
);
endmodule

`endif
