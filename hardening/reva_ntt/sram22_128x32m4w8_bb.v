// SPDX-License-Identifier: Apache-2.0
// Black-box synthesis/header view for the pinned SRAM22 hard macro.
(* blackbox *) module sram22_128x32m4w8 (
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
