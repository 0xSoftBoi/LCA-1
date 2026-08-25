// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_ntt_sram22_differential_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg zeroize_i = 1'b0;
    reg start_i = 1'b0;
    reg [1:0] command_i = 2'd0;
    reg coeff_we_i = 1'b0;
    reg [7:0] coeff_addr_i = 8'd0;
    reg [31:0] coeff_wdata_i = 32'd0;
    reg [3:0] coeff_wstrb_i = 4'd0;

    wire old_busy, old_done;
    wire [31:0] old_rdata;
    wire new_busy, new_done;
    wire [31:0] new_rdata;

    integer i;
    integer cycles;
    integer q;
    reg [31:0] value;

    lca_ntt_accel oracle (
        .clk_i, .rst_ni, .zeroize_i, .start_i, .command_i,
        .busy_o(old_busy), .done_o(old_done),
        .coeff_we_i, .coeff_addr_i, .coeff_wdata_i, .coeff_wstrb_i,
        .coeff_rdata_o(old_rdata)
    );

    lca_ntt_accel_sram22 candidate (
        .clk_i, .rst_ni, .zeroize_i, .start_i, .command_i,
        .busy_o(new_busy), .done_o(new_done),
        .coeff_we_i, .coeff_addr_i, .coeff_wdata_i, .coeff_wstrb_i,
        .coeff_rdata_o(new_rdata)
    );

    always #5 clk_i = ~clk_i;
    task tick; begin @(posedge clk_i); #1; end endtask

    task load_pattern(input [1:0] cmd);
        begin
            q = (cmd < 2) ? 8380417 : 3329;
            coeff_we_i = 1'b1;
            coeff_wstrb_i = 4'hf;
            for (i = 0; i < 256; i = i + 1) begin
                coeff_addr_i = i[7:0];
                value = ((i * 32'd12345) + (cmd * 32'd7919) + 32'd17) % q;
                coeff_wdata_i = value;
                tick();
            end
            coeff_we_i = 1'b0;
            coeff_wstrb_i = 4'h0;
            tick();
        end
    endtask

    task compare_all(input [1:0] cmd);
        begin
            for (i = 0; i < 256; i = i + 1) begin
                coeff_addr_i = i[7:0];
                // Candidate is registered-read; oracle is combinational.
                tick();
                if (new_rdata !== old_rdata) begin
                    $display("FAIL cmd=%0d coeff=%0d oracle=%08x sram22=%08x", cmd, i, old_rdata, new_rdata);
                    $fatal(1);
                end
            end
        end
    endtask

    task run_command(input [1:0] cmd);
        begin
            load_pattern(cmd);
            command_i = cmd;
            start_i = 1'b1;
            tick();
            start_i = 1'b0;
            cycles = 0;
            while (!(old_done && new_done) && cycles < 5000) begin
                tick();
                cycles = cycles + 1;
            end
            if (!(old_done && new_done))
                $fatal(1, "command %0d timed out old_busy=%0d new_busy=%0d", cmd, old_busy, new_busy);
            if (new_busy || old_busy)
                $fatal(1, "done asserted while busy for command %0d", cmd);
            compare_all(cmd);
            $display("PASS command=%0d differential cycles=%0d", cmd, cycles);
        end
    endtask

    initial begin
        repeat (3) tick();
        rst_ni = 1'b1;
        tick();

        run_command(2'd0); // ML-DSA forward
        run_command(2'd1); // ML-DSA inverse + scale
        run_command(2'd2); // ML-KEM forward
        run_command(2'd3); // ML-KEM inverse + scale

        // Both architectures must destroy all coefficient data on zeroize;
        // their physical scrub latencies intentionally differ (256 vs 128).
        zeroize_i = 1'b1;
        tick();
        zeroize_i = 1'b0;
        cycles = 0;
        while ((old_busy || new_busy) && cycles < 300) begin
            tick();
            cycles = cycles + 1;
        end
        if (old_busy || new_busy) $fatal(1, "zeroize timeout");
        compare_all(2'd3);

        $display("PASS: SRAM22 two-phase NTT is coefficient-equivalent to the existing oracle for all four commands");
        $finish;
    end
endmodule
