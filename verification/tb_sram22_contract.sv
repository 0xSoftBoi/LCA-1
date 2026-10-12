// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_sram22_contract_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg ce_i = 1'b0;
    reg we_i = 1'b0;
    reg [3:0] wmask_i = 4'd0;
    reg [6:0] addr128 = 7'd0;
    reg [10:0] addr2048 = 11'd0;
    reg [31:0] wdata_i = 32'd0;
    wire [31:0] rdata128;
    wire [31:0] rdata2048;

    lca_sram22_128x32 u128 (
        .clk_i, .rst_ni, .ce_i, .we_i, .wmask_i,
        .addr_i(addr128), .wdata_i, .rdata_o(rdata128)
    );
    lca_sram22_2048x32 u2048 (
        .clk_i, .rst_ni, .ce_i, .we_i, .wmask_i,
        .addr_i(addr2048), .wdata_i, .rdata_o(rdata2048)
    );

    always #5 clk_i = ~clk_i;
    task tick; begin @(posedge clk_i); #1; end endtask

    initial begin
        repeat (2) tick();
        rst_ni = 1'b1;

        // Full-word writes to both macro classes.
        ce_i = 1'b1; we_i = 1'b1; wmask_i = 4'hf;
        addr128 = 7'd37; addr2048 = 11'd1337; wdata_i = 32'h11223344;
        tick();

        // SRAM22 is registered-read: the requested word appears after a read clock.
        we_i = 1'b0; wmask_i = 4'h0;
        tick();
        if (rdata128 !== 32'h11223344 || rdata2048 !== 32'h11223344)
            $fatal(1, "registered read contract mismatch");

        // Byte masks must match the physical macro's wmask semantics.
        we_i = 1'b1; wmask_i = 4'b0101; wdata_i = 32'haabbccdd;
        tick();
        we_i = 1'b0; wmask_i = 4'h0;
        tick();
        if (rdata128 !== 32'h11bb33dd || rdata2048 !== 32'h11bb33dd)
            $fatal(1, "byte-mask contract mismatch: 128=%08x 2048=%08x", rdata128, rdata2048);

        // Chip disable must hold the registered output stable.
        ce_i = 1'b0; addr128 = 7'd0; addr2048 = 11'd0;
        repeat (3) tick();
        if (rdata128 !== 32'h11bb33dd || rdata2048 !== 32'h11bb33dd)
            $fatal(1, "CE hold contract mismatch");

        $display("PASS: SRAM22 wrappers match synchronous single-port read/write/mask semantics");
        $finish;
    end
endmodule
