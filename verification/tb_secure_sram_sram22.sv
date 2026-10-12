// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_secure_sram_sram22_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg zeroize_i = 1'b0;
    wire zeroize_busy_o;
    reg req_valid_i = 1'b0;
    wire req_ready_o;
    reg req_write_i = 1'b0;
    reg [12:0] req_addr_i = 13'd0;
    reg [31:0] req_wdata_i = 32'd0;
    reg [3:0] req_wstrb_i = 4'd0;
    wire rsp_valid_o;
    reg rsp_ready_i = 1'b1;
    wire [31:0] rsp_rdata_o;
    integer cycles;

    lca_secure_sram_sram22 dut (.*);
    always #5 clk_i = ~clk_i;
    task tick; begin @(posedge clk_i); #1; end endtask

    task write_word(input [12:0] addr, input [31:0] data, input [3:0] mask);
        begin
            while (!req_ready_o) tick();
            req_addr_i = addr; req_wdata_i = data; req_wstrb_i = mask;
            req_write_i = 1'b1; req_valid_i = 1'b1;
            tick(); req_valid_i = 1'b0; req_write_i = 1'b0;
            if (!rsp_valid_o) $fatal(1, "write response missing");
            tick();
        end
    endtask

    task read_word(input [12:0] addr, input [31:0] expected);
        begin
            while (!req_ready_o) tick();
            req_addr_i = addr; req_write_i = 1'b0; req_valid_i = 1'b1;
            tick(); req_valid_i = 1'b0;
            if (rsp_valid_o) $fatal(1, "read response arrived before registered SRAM data was available");
            tick();
            if (!rsp_valid_o || rsp_rdata_o !== expected)
                $fatal(1, "read mismatch addr=%0d expected=%08x got=%08x valid=%0d", addr, expected, rsp_rdata_o, rsp_valid_o);
            tick();
        end
    endtask

    initial begin
        repeat (2) tick();
        rst_ni = 1'b1;

        // Touch every bank with a distinct row/address.
        write_word(13'h001, 32'h11111111, 4'hf);
        write_word(13'h801, 32'h22222222, 4'hf);
        write_word(13'h1001, 32'h33333333, 4'hf);
        write_word(13'h1801, 32'h44444444, 4'hf);
        read_word(13'h001, 32'h11111111);
        read_word(13'h801, 32'h22222222);
        read_word(13'h1001, 32'h33333333);
        read_word(13'h1801, 32'h44444444);

        // Byte-mask semantics survive through the fabric.
        write_word(13'h1001, 32'haabbccdd, 4'b0101);
        read_word(13'h1001, 32'h33bb33dd);

        // Response backpressure must prevent a new request.
        rsp_ready_i = 1'b0;
        while (!req_ready_o) tick();
        req_addr_i = 13'h001; req_valid_i = 1'b1; req_write_i = 1'b0;
        tick(); req_valid_i = 1'b0;
        tick();
        if (!rsp_valid_o || req_ready_o) $fatal(1, "response backpressure invariant broken");
        repeat (3) begin tick(); if (!rsp_valid_o || req_ready_o) $fatal(1, "response did not hold"); end
        rsp_ready_i = 1'b1; tick();

        // Four banks scrub in parallel: exactly 2048 physical row writes.
        zeroize_i = 1'b1; tick(); zeroize_i = 1'b0;
        if (!zeroize_busy_o || req_ready_o) $fatal(1, "zeroize did not seize SRAM fabric");
        cycles = 0;
        while (zeroize_busy_o && cycles < 2100) begin tick(); cycles = cycles + 1; end
        if (cycles != 2048) $fatal(1, "zeroize latency changed: %0d", cycles);
        read_word(13'h001, 32'd0);
        read_word(13'h801, 32'd0);
        read_word(13'h1001, 32'd0);
        read_word(13'h1801, 32'd0);

        $display("PASS: four-bank SRAM22 secure SRAM read/write/backpressure/byte-mask/2048-cycle scrub");
        $finish;
    end
endmodule
