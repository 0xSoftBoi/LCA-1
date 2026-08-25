// SPDX-License-Identifier: Apache-2.0
//
// Rev-A 32 KiB secure SRAM built from four qualified 2048x32 1RW macros.
//
// The external shape intentionally matches the older portable secure-SRAM
// wrapper so the host/scrub arbitration remains at the core boundary. A cycle
// with any write strobe performs one write; otherwise the selected read bank is
// enabled and its registered output becomes visible on rdata_o after the edge.

`default_nettype none

module lca_secure_sram_reva (
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire [12:0]  raddr_i,
    output wire [31:0]  rdata_o,
    input  wire [12:0]  waddr_i,
    input  wire [31:0]  wdata_i,
    input  wire [3:0]   wstrb_i
);
    wire write_cycle = |wstrb_i;
    wire [1:0] active_bank = write_cycle ? waddr_i[12:11] : raddr_i[12:11];
    wire [10:0] active_row = write_cycle ? waddr_i[10:0] : raddr_i[10:0];

    reg [1:0] read_bank_q;
    wire [31:0] bank0_rdata;
    wire [31:0] bank1_rdata;
    wire [31:0] bank2_rdata;
    wire [31:0] bank3_rdata;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            read_bank_q <= 2'd0;
        else if (!write_cycle)
            read_bank_q <= active_bank;
    end

    assign rdata_o =
        (read_bank_q == 2'd0) ? bank0_rdata :
        (read_bank_q == 2'd1) ? bank1_rdata :
        (read_bank_q == 2'd2) ? bank2_rdata : bank3_rdata;

    lca_sram_1rw #(.WORDS(2048), .ADDR_W(11)) u_bank0 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(active_bank == 2'd0),
        .we_i(write_cycle && active_bank == 2'd0),
        .wmask_i((active_bank == 2'd0) ? wstrb_i : 4'd0),
        .addr_i(active_row), .wdata_i(wdata_i), .rdata_o(bank0_rdata)
    );
    lca_sram_1rw #(.WORDS(2048), .ADDR_W(11)) u_bank1 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(active_bank == 2'd1),
        .we_i(write_cycle && active_bank == 2'd1),
        .wmask_i((active_bank == 2'd1) ? wstrb_i : 4'd0),
        .addr_i(active_row), .wdata_i(wdata_i), .rdata_o(bank1_rdata)
    );
    lca_sram_1rw #(.WORDS(2048), .ADDR_W(11)) u_bank2 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(active_bank == 2'd2),
        .we_i(write_cycle && active_bank == 2'd2),
        .wmask_i((active_bank == 2'd2) ? wstrb_i : 4'd0),
        .addr_i(active_row), .wdata_i(wdata_i), .rdata_o(bank2_rdata)
    );
    lca_sram_1rw #(.WORDS(2048), .ADDR_W(11)) u_bank3 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(active_bank == 2'd3),
        .we_i(write_cycle && active_bank == 2'd3),
        .wmask_i((active_bank == 2'd3) ? wstrb_i : 4'd0),
        .addr_i(active_row), .wdata_i(wdata_i), .rdata_o(bank3_rdata)
    );

endmodule

`default_nettype wire
