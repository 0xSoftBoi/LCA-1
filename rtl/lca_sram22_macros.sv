// SPDX-License-Identifier: Apache-2.0
//
// Stable LCA-1 wrappers for the pinned SRAM22 SKY130 macros.
//
// Define LCA_PHYSICAL_SRAM22 for PnR/signoff builds, where the external
// sram22_* modules are supplied as black boxes plus LEF/GDS/Liberty views.
// Normal RTL CI uses the cycle-accurate synchronous fallback below. The
// fallback deliberately matches SRAM22's single-port registered-read contract;
// it is not the old asynchronous inferred-memory model.

`default_nettype none

module lca_sram22_128x32 (
`ifdef USE_POWER_PINS
    inout wire        vdd,
    inout wire        vss,
`endif
    input  wire        clk_i,
    input  wire        rst_ni,
    input  wire        ce_i,
    input  wire        we_i,
    input  wire [3:0]  wmask_i,
    input  wire [6:0]  addr_i,
    input  wire [31:0] wdata_i,
    output wire [31:0] rdata_o
);
`ifdef LCA_PHYSICAL_SRAM22
    sram22_128x32m4w8 u_macro (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk(clk_i), .rstb(rst_ni), .ce(ce_i), .we(we_i),
        .wmask(wmask_i), .addr(addr_i), .din(wdata_i), .dout(rdata_o)
    );
`else
    reg [31:0] mem [0:127];
    reg [31:0] rdata_q;
    assign rdata_o = rdata_q;
    always @(posedge clk_i) begin
        if (ce_i && rst_ni) begin
            if (we_i) begin
                if (wmask_i[0]) mem[addr_i][7:0]   <= wdata_i[7:0];
                if (wmask_i[1]) mem[addr_i][15:8]  <= wdata_i[15:8];
                if (wmask_i[2]) mem[addr_i][23:16] <= wdata_i[23:16];
                if (wmask_i[3]) mem[addr_i][31:24] <= wdata_i[31:24];
            end else begin
                rdata_q <= mem[addr_i];
            end
        end
    end
`endif
endmodule

module lca_sram22_2048x32 (
`ifdef USE_POWER_PINS
    inout wire         vdd,
    inout wire         vss,
`endif
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         ce_i,
    input  wire         we_i,
    input  wire [3:0]   wmask_i,
    input  wire [10:0]  addr_i,
    input  wire [31:0]  wdata_i,
    output wire [31:0]  rdata_o
);
`ifdef LCA_PHYSICAL_SRAM22
    sram22_2048x32m8w8 u_macro (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk(clk_i), .rstb(rst_ni), .ce(ce_i), .we(we_i),
        .wmask(wmask_i), .addr(addr_i), .din(wdata_i), .dout(rdata_o)
    );
`else
    reg [31:0] mem [0:2047];
    reg [31:0] rdata_q;
    assign rdata_o = rdata_q;
    always @(posedge clk_i) begin
        if (ce_i && rst_ni) begin
            if (we_i) begin
                if (wmask_i[0]) mem[addr_i][7:0]   <= wdata_i[7:0];
                if (wmask_i[1]) mem[addr_i][15:8]  <= wdata_i[15:8];
                if (wmask_i[2]) mem[addr_i][23:16] <= wdata_i[23:16];
                if (wmask_i[3]) mem[addr_i][31:24] <= wdata_i[31:24];
            end else begin
                rdata_q <= mem[addr_i];
            end
        end
    end
`endif
endmodule

`default_nettype wire
