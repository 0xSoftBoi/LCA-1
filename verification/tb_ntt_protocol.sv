// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_ntt_protocol_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg zeroize_i = 1'b0;
    reg start_i = 1'b0;
    reg [1:0] command_i = 2'd0;
    wire busy_o;
    wire done_o;
    reg coeff_we_i = 1'b0;
    reg [7:0] coeff_addr_i = 8'd0;
    reg [31:0] coeff_wdata_i = 32'd0;
    reg [3:0] coeff_wstrb_i = 4'd0;
    wire [31:0] coeff_rdata_o;

    integer cycles;

    lca_ntt_accel dut (
        .clk_i,
        .rst_ni,
        .zeroize_i,
        .start_i,
        .command_i,
        .busy_o,
        .done_o,
        .coeff_we_i,
        .coeff_addr_i,
        .coeff_wdata_i,
        .coeff_wstrb_i,
        .coeff_rdata_o
    );

    always #5 clk_i = ~clk_i;

    task tick;
        begin
            @(posedge clk_i);
            #1;
        end
    endtask

    task write_word(input [7:0] address, input [31:0] value);
        begin
            coeff_addr_i = address;
            coeff_wdata_i = value;
            coeff_wstrb_i = 4'hf;
            coeff_we_i = 1'b1;
            tick();
            coeff_we_i = 1'b0;
            coeff_wstrb_i = 4'h0;
        end
    endtask

    task expect_word(input [7:0] address, input [31:0] value);
        begin
            // Rev-A SRAM is synchronous 1RW: present the address for one idle
            // read clock before sampling the registered output.
            coeff_addr_i = address;
            coeff_we_i = 1'b0;
            tick();
            if (coeff_rdata_o !== value) begin
                $display("FAIL: coeff[%0d] expected %08x got %08x", address, value, coeff_rdata_o);
                $fatal(1);
            end
        end
    endtask

    initial begin
        repeat (2) tick();
        rst_ni = 1'b1;
        tick();

        write_word(8'd0,   32'h11223344);
        write_word(8'd127, 32'h55667788);
        write_word(8'd255, 32'h99aabbcc);
        expect_word(8'd0,   32'h11223344);
        expect_word(8'd127, 32'h55667788);
        expect_word(8'd255, 32'h99aabbcc);

        zeroize_i = 1'b1;
        tick();
        zeroize_i = 1'b0;
        if (!busy_o || done_o) $fatal(1, "zeroize did not enter busy fail-closed state");

        cycles = 0;
        while (busy_o && cycles < 300) begin
            tick();
            cycles = cycles + 1;
        end
        if (cycles != 256) $fatal(1, "zeroize latency changed: got %0d expected 256", cycles);
        if (busy_o) $fatal(1, "zeroize did not complete");
        if (done_o) $fatal(1, "zeroize must not masquerade as transform completion");
        expect_word(8'd0,   32'd0);
        expect_word(8'd127, 32'd0);
        expect_word(8'd255, 32'd0);

        write_word(8'd17, 32'hdeadbeef);
        zeroize_i = 1'b1;
        tick();
        cycles = 0;
        while (busy_o && cycles < 300) begin
            tick();
            cycles = cycles + 1;
        end
        if (cycles != 256 || busy_o) $fatal(1, "held zeroize failed to finish exactly once");
        repeat (8) begin
            start_i = 1'b1;
            tick();
            if (busy_o) $fatal(1, "start accepted while zeroize remained asserted");
        end
        start_i = 1'b0;
        expect_word(8'd17, 32'd0);
        zeroize_i = 1'b0;
        tick();

        // Two SRAM phases per butterfly plus two phases per inverse scaling
        // element put ML-DSA INTT below 2,700 cycles. Keep headroom but make a
        // scheduler regression visible.
        command_i = 2'd1;
        start_i = 1'b1;
        tick();
        start_i = 1'b0;
        cycles = 0;
        while (busy_o && cycles < 3000) begin
            tick();
            cycles = cycles + 1;
        end
        if (busy_o || !done_o) $fatal(1, "post-zeroize ML-DSA INTT did not complete");
        if (cycles > 2700) $fatal(1, "macro-backed ML-DSA INTT scheduler regressed: %0d cycles", cycles);
        expect_word(8'd0, 32'd0);
        expect_word(8'd127, 32'd0);
        expect_word(8'd255, 32'd0);

        $display("PASS: NTT uses synchronous 1RW banks; zeroize and transform scheduling recover cleanly, INTT cycles=%0d", cycles);
        $finish;
    end
endmodule
