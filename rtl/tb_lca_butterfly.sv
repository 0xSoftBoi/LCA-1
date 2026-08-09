`timescale 1ns/1ps
`default_nettype none

module tb_lca_butterfly;
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic req_valid = 1'b0;
    logic req_ready;
    logic [1:0] req_modulus_id = '0;
    logic [23:0] req_a = '0;
    logic [23:0] req_b = '0;
    logic [23:0] req_twiddle = '0;
    logic rsp_valid;
    logic rsp_ready = 1'b0;
    logic rsp_fault;
    logic [23:0] rsp_a;
    logic [23:0] rsp_b;
    integer failures = 0;

    always #5 clk = ~clk;

    lca_butterfly dut (
        .clk, .rst_n,
        .req_valid, .req_ready, .req_modulus_id,
        .req_a, .req_b, .req_twiddle,
        .rsp_valid, .rsp_ready, .rsp_fault, .rsp_a, .rsp_b
    );

    task automatic run_case(
        input logic [1:0] modulus_id,
        input logic [23:0] a,
        input logic [23:0] b,
        input logic [23:0] twiddle,
        input logic [23:0] expected_a,
        input logic [23:0] expected_b
    );
        integer cycles;
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_modulus_id = modulus_id;
            req_a = a;
            req_b = b;
            req_twiddle = twiddle;
            req_valid = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;

            cycles = 0;
            while (!rsp_valid) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (cycles != 24) begin
                $display("FAIL latency: got %0d expected 24", cycles);
                failures = failures + 1;
            end
            if (rsp_fault || rsp_a !== expected_a || rsp_b !== expected_b) begin
                $display("FAIL qid=%0d a=%0d b=%0d w=%0d -> (%0d,%0d) fault=%0b expected=(%0d,%0d)",
                         modulus_id, a, b, twiddle, rsp_a, rsp_b, rsp_fault, expected_a, expected_b);
                failures = failures + 1;
            end
            rsp_ready = 1'b1;
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    task automatic run_fault_case;
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_modulus_id = 2'd0;
            req_a = 24'd3329;
            req_b = 24'd1;
            req_twiddle = 24'd1;
            req_valid = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;
            while (!rsp_valid) @(negedge clk);
            if (!rsp_fault) begin
                $display("FAIL invalid coefficient did not fault");
                failures = failures + 1;
            end
            rsp_ready = 1'b1;
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        run_case(2'd0, 24'd1, 24'd2, 24'd3, 24'd7, 24'd3324);
        run_case(2'd0, 24'd3328, 24'd3328, 24'd3328, 24'd0, 24'd3327);
        run_case(2'd0, 24'd1234, 24'd2345, 24'd3210, 24'd1815, 24'd653);
        run_case(2'd1, 24'd1, 24'd2, 24'd3, 24'd7, 24'd8380412);
        run_case(2'd1, 24'd8380416, 24'd8380416, 24'd8380416, 24'd0, 24'd8380415);
        run_case(2'd1, 24'd1234567, 24'd7654321, 24'd543210, 24'd2952512, 24'd7897039);
        run_fault_case();

        if (failures == 0) begin
            $display("PASS lca_butterfly");
            $finish;
        end
        $fatal(1, "%0d failures", failures);
    end
endmodule

`default_nettype wire
