// SPDX-License-Identifier: Apache-2.0
//
// lca_sram_fit - 32 KiB compiled-SRAM bank wrapper, built solely to measure a
// SKY130 fit. This is a *hardening probe*, not Rev-A RTL: it has no CSR
// interface, no zeroize sequencer, no tamper handling, and no error reporting,
// all of which fabrication/rev_a_release.json requires of the real memory
// block. Its only job is to instantiate the selected macro array so that
// LibreLane can report area, timing, DRC and LVS for that array in context.
//
// Organisation: 8192 words x 32 bits = 32 KiB, built from 16 instances of
// sky130_sram_2kbyte_1rw1r_32x512_8 (512 words x 32 bits each), the largest
// 32-bit-word OpenRAM SKY130 macro for which a placeable LEF/GDS view is
// actually distributed. See docs/SRAM_DECISION.md for why that macro, and
// tools/sram_area.py for the area arithmetic.
//
//   addr[12:9] selects the bank, addr[8:0] selects the word inside it.
//
// Both macro ports are used, matching the intended Rev-A access pattern: port
// 0 is the read/write host-stream port, port 1 is a read-only coefficient
// port. Macro reads are registered: data appears on the cycle after the edge
// that accepted the address, so the read multiplexer uses a delayed copy of
// the bank select.
//
// The macro is a black box here; its declaration comes from
// sky130_sram_2kbyte_1rw1r_32x512_8.vh, which mirrors the port list of the
// upstream Apache-2.0 behavioural model at
// https://github.com/VLSIDA/sky130_sram_macros @ 965df150c7 .

`default_nettype none

module lca_sram_fit #(
    parameter integer BANKS          = 16,
    parameter integer BANK_SEL_BITS  = 4,
    parameter integer BANK_ADDR_BITS = 9,
    parameter integer DATA_BITS      = 32,
    parameter integer MASK_BITS      = 4,
    parameter integer ADDR_BITS      = BANK_SEL_BITS + BANK_ADDR_BITS
) (
`ifdef USE_POWER_PINS
    inout  wire                 VPWR,
    inout  wire                 VGND,
`endif
    input  wire                 clk,
    input  wire                 rst_n,

    // Port 0: read/write (host stream side).
    input  wire                 p0_en,
    input  wire                 p0_we,
    input  wire [MASK_BITS-1:0] p0_wmask,
    input  wire [ADDR_BITS-1:0] p0_addr,
    input  wire [DATA_BITS-1:0] p0_wdata,
    output wire [DATA_BITS-1:0] p0_rdata,

    // Port 1: read only (coefficient side).
    input  wire                 p1_en,
    input  wire [ADDR_BITS-1:0] p1_addr,
    output wire [DATA_BITS-1:0] p1_rdata
);

    // ---------------------------------------------------------------- decode
    wire [BANK_SEL_BITS-1:0]  p0_sel = p0_addr[ADDR_BITS-1:BANK_ADDR_BITS];
    wire [BANK_SEL_BITS-1:0]  p1_sel = p1_addr[ADDR_BITS-1:BANK_ADDR_BITS];

    wire [BANKS-1:0] p0_hit = p0_en ? ({{(BANKS-1){1'b0}}, 1'b1} << p0_sel)
                                    : {BANKS{1'b0}};
    wire [BANKS-1:0] p1_hit = p1_en ? ({{(BANKS-1){1'b0}}, 1'b1} << p1_sel)
                                    : {BANKS{1'b0}};

    // The macros use active-low chip select and active-low write enable.
    wire [BANKS-1:0] csb0 = ~p0_hit;
    wire [BANKS-1:0] csb1 = ~p1_hit;
    wire             web0 = ~p0_we;

    // ------------------------------------------------- read-select pipeline
    reg [BANK_SEL_BITS-1:0] p0_sel_q;
    reg [BANK_SEL_BITS-1:0] p1_sel_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0_sel_q <= {BANK_SEL_BITS{1'b0}};
            p1_sel_q <= {BANK_SEL_BITS{1'b0}};
        end else begin
            if (p0_en) p0_sel_q <= p0_sel;
            if (p1_en) p1_sel_q <= p1_sel;
        end
    end

    // ----------------------------------------------------------- macro array
    // Instance-array form, so the flattened instance names are u_bank[0] ...
    // u_bank[15] and match the MACROS instance keys in config.json exactly.
    // Per-instance nets (csb, dout) are BANKS-wide/BANKS*DATA_BITS-wide and are
    // split across instances; single-width nets (clk, addr, din) broadcast.
    wire [BANKS*DATA_BITS-1:0] dout0_flat;
    wire [BANKS*DATA_BITS-1:0] dout1_flat;

    sky130_sram_2kbyte_1rw1r_32x512_8 u_bank [BANKS-1:0] (
`ifdef USE_POWER_PINS
        .vccd1  (VPWR),
        .vssd1  (VGND),
`endif
        .clk0   (clk),
        .csb0   (csb0),
        .web0   (web0),
        .wmask0 (p0_wmask),
        .addr0  (p0_addr[BANK_ADDR_BITS-1:0]),
        .din0   (p0_wdata),
        .dout0  (dout0_flat),
        .clk1   (clk),
        .csb1   (csb1),
        .addr1  (p1_addr[BANK_ADDR_BITS-1:0]),
        .dout1  (dout1_flat)
    );

    // -------------------------------------------------------------- read mux
    assign p0_rdata = dout0_flat[p0_sel_q*DATA_BITS +: DATA_BITS];
    assign p1_rdata = dout1_flat[p1_sel_q*DATA_BITS +: DATA_BITS];

endmodule

`default_nettype wire
