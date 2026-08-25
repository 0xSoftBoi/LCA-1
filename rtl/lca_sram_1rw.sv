// SPDX-License-Identifier: Apache-2.0
//
// Synchronous byte-write single-port SRAM contract for LCA-1 Rev-A.
//
// Behavioral builds use the inferred model below. SKY130 macro builds define
// LCA_USE_SRAM22 and bind only the two Rev-A-qualified shapes:
//   * 128 x 32  -- one NTT coefficient bank
//   * 2048 x 32 -- one quarter of the 32 KiB secure SRAM
//
// Read data is registered. A port performs either one read or one write on a
// rising edge; this intentionally matches SRAM22 instead of hiding a fictitious
// asynchronous read behind the portable model.

`default_nettype none

module lca_sram_1rw #(
    parameter integer WORDS = 128,
    parameter integer ADDR_W = $clog2(WORDS)
) (
    input  wire               clk_i,
    input  wire               rst_ni,
    input  wire               ce_i,
    input  wire               we_i,
    input  wire [3:0]         wmask_i,
    input  wire [ADDR_W-1:0]  addr_i,
    input  wire [31:0]        wdata_i,
    output wire [31:0]        rdata_o
);

`ifdef LCA_USE_SRAM22
    generate
        if (WORDS == 128 && ADDR_W == 7) begin : g_sram22_128
            sram22_128x32m4w8 u_macro (
`ifdef USE_POWER_PINS
                .vdd(vccd1),
                .vss(vssd1),
`endif
                .clk(clk_i),
                .rstb(rst_ni),
                .ce(ce_i),
                .we(we_i),
                .wmask(wmask_i),
                .addr(addr_i),
                .din(wdata_i),
                .dout(rdata_o)
            );
        end else if (WORDS == 2048 && ADDR_W == 11) begin : g_sram22_2048
            sram22_2048x32m8w8 u_macro (
`ifdef USE_POWER_PINS
                .vdd(vccd1),
                .vss(vssd1),
`endif
                .clk(clk_i),
                .rstb(rst_ni),
                .ce(ce_i),
                .we(we_i),
                .wmask(wmask_i),
                .addr(addr_i),
                .din(wdata_i),
                .dout(rdata_o)
            );
        end else begin : g_unsupported_shape
            // Deliberately fail elaboration for unqualified macro shapes.
            initial $error("Unsupported LCA-1 SRAM22 shape WORDS=%0d ADDR_W=%0d", WORDS, ADDR_W);
            assign rdata_o = 32'd0;
        end
    endgenerate
`else
    reg [31:0] mem_q [0:WORDS-1];
    reg [31:0] rdata_q;

    assign rdata_o = rdata_q;

    always @(posedge clk_i) begin
        if (ce_i && rst_ni) begin
            if (we_i) begin
                if (wmask_i[0]) mem_q[addr_i][7:0]   <= wdata_i[7:0];
                if (wmask_i[1]) mem_q[addr_i][15:8]  <= wdata_i[15:8];
                if (wmask_i[2]) mem_q[addr_i][23:16] <= wdata_i[23:16];
                if (wmask_i[3]) mem_q[addr_i][31:24] <= wdata_i[31:24];
            end else begin
                rdata_q <= mem_q[addr_i];
            end
        end
    end
`endif

endmodule

`default_nettype wire
