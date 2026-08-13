// SPDX-License-Identifier: Apache-2.0
//
// Portable one-read/one-write secure SRAM model. ASIC targets replace this
// module with a compiled macro wrapper of identical behavior. Keeping all
// writes behind one address and byte-enable port prevents synthesis from
// flattening the full working memory into flip-flops.

module lca_secure_sram #(
    parameter integer WORDS = 131072,
    parameter integer ADDR_W = $clog2(WORDS)
) (
    input  wire                clk_i,
    input  wire [ADDR_W-1:0]   raddr_i,
    output wire [31:0]         rdata_o,
    input  wire [ADDR_W-1:0]   waddr_i,
    input  wire [31:0]         wdata_i,
    input  wire [3:0]          wstrb_i
);

    reg [31:0] mem [0:WORDS-1];

    assign rdata_o = mem[raddr_i];

    always @(posedge clk_i) begin
        if (wstrb_i[0]) mem[waddr_i][7:0]   <= wdata_i[7:0];
        if (wstrb_i[1]) mem[waddr_i][15:8]  <= wdata_i[15:8];
        if (wstrb_i[2]) mem[waddr_i][23:16] <= wdata_i[23:16];
        if (wstrb_i[3]) mem[waddr_i][31:24] <= wdata_i[31:24];
    end

endmodule
