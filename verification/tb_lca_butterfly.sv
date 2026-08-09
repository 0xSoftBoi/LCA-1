`timescale 1ns/1ps
`default_nettype none

module tb_lca_butterfly;
    localparam integer MAX_WAIT_CYCLES = 32;

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
    integer cases_run = 0;

    always #5 clk = ~clk;

    lca_butterfly dut (
        .clk, .rst_n,
        .req_valid, .req_ready, .req_modulus_id,
        .req_a, .req_b, .req_twiddle,
        .rsp_valid, .rsp_ready, .rsp_fault, .rsp_a, .rsp_b
    );

    task automatic run_vector(
        input integer case_id,
        input integer modulus_id,
        input integer a,
        input integer b,
        input integer twiddle,
        input integer expected_a,
        input integer expected_b,
        input integer expected_fault,
        input integer hold_cycles,
        input integer expected_latency
    );
        integer cycles;
        integer hold_index;
        logic held_fault;
        logic [23:0] held_a;
        logic [23:0] held_b;
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);

            req_modulus_id = modulus_id[1:0];
            req_a = a[23:0];
            req_b = b[23:0];
            req_twiddle = twiddle[23:0];
            req_valid = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;

            cycles = 0;
            while (!rsp_valid && cycles <= MAX_WAIT_CYCLES) begin
                @(negedge clk);
                cycles = cycles + 1;
            end

            if (!rsp_valid) begin
                $display("FAIL case=%0d response timeout", case_id);
                failures = failures + 1;
            end else begin
                if (cycles != expected_latency) begin
                    $display(
                        "FAIL case=%0d latency got=%0d expected=%0d",
                        case_id, cycles, expected_latency
                    );
                    failures = failures + 1;
                end
                if (rsp_fault !== expected_fault[0] ||
                    rsp_a !== expected_a[23:0] ||
                    rsp_b !== expected_b[23:0]) begin
                    $display(
                        "FAIL case=%0d qid=%0d a=%0d b=%0d w=%0d "
                        "got=(%0d,%0d,f=%0b) expected=(%0d,%0d,f=%0d)",
                        case_id, modulus_id, a, b, twiddle,
                        rsp_a, rsp_b, rsp_fault,
                        expected_a, expected_b, expected_fault
                    );
                    failures = failures + 1;
                end

                held_fault = rsp_fault;
                held_a = rsp_a;
                held_b = rsp_b;
                for (hold_index = 0; hold_index < hold_cycles; hold_index = hold_index + 1) begin
                    @(negedge clk);
                    if (!rsp_valid || req_ready || rsp_fault !== held_fault ||
                        rsp_a !== held_a || rsp_b !== held_b) begin
                        $display("FAIL case=%0d response changed under backpressure", case_id);
                        failures = failures + 1;
                    end
                end

                rsp_ready = 1'b1;
                @(negedge clk);
                rsp_ready = 1'b0;
                if (rsp_valid) begin
                    $display("FAIL case=%0d response did not retire", case_id);
                    failures = failures + 1;
                end
            end

            cases_run = cases_run + 1;
        end
    endtask

    task automatic run_reset_cancellation;
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_modulus_id = 2'd1;
            req_a = 24'd1234567;
            req_b = 24'd7654321;
            req_twiddle = 24'd543210;
            req_valid = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;

            repeat (5) @(negedge clk);
            rst_n = 1'b0;
            @(negedge clk);
            if (rsp_valid || rsp_fault || rsp_a !== 24'd0 || rsp_b !== 24'd0) begin
                $display("FAIL reset did not cancel and clear the in-flight operation");
                failures = failures + 1;
            end
            rst_n = 1'b1;
            @(negedge clk);
            if (!req_ready) begin
                $display("FAIL interface did not recover after reset");
                failures = failures + 1;
            end
        end
    endtask

    integer vector_file;
    integer scan_count;
    integer format_version;
    integer vector_count;
    integer corpus_seed;
    integer index;
    integer case_id_raw;
    integer modulus_id_raw;
    integer a_raw;
    integer b_raw;
    integer twiddle_raw;
    integer expected_a_raw;
    integer expected_b_raw;
    integer expected_fault_raw;
    integer hold_cycles_raw;
    integer expected_latency_raw;

    initial begin
        vector_file = $fopen("verification/vectors/butterfly_vectors.txt", "r");
        if (vector_file == 0)
            $fatal(1, "cannot open verification/vectors/butterfly_vectors.txt");

        scan_count = $fscanf(
            vector_file,
            "%d %d %d\n",
            format_version,
            vector_count,
            corpus_seed
        );
        if (scan_count != 3 || format_version != 1)
            $fatal(1, "invalid vector corpus header");

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        for (index = 0; index < vector_count; index = index + 1) begin
            scan_count = $fscanf(
                vector_file,
                "%d %d %d %d %d %d %d %d %d %d\n",
                case_id_raw,
                modulus_id_raw,
                a_raw,
                b_raw,
                twiddle_raw,
                expected_a_raw,
                expected_b_raw,
                expected_fault_raw,
                hold_cycles_raw,
                expected_latency_raw
            );
            if (scan_count != 10)
                $fatal(1, "invalid vector row index=%0d fields=%0d", index, scan_count);
            if (case_id_raw != index)
                $fatal(1, "non-sequential case id=%0d index=%0d", case_id_raw, index);
            run_vector(
                case_id_raw,
                modulus_id_raw,
                a_raw,
                b_raw,
                twiddle_raw,
                expected_a_raw,
                expected_b_raw,
                expected_fault_raw,
                hold_cycles_raw,
                expected_latency_raw
            );
        end
        $fclose(vector_file);

        run_reset_cancellation();

        if (failures == 0) begin
            $display(
                "PASS lca_butterfly corpus cases=%0d seed=%0d reset_cases=1",
                cases_run, corpus_seed
            );
            $finish;
        end
        $fatal(1, "%0d failures across %0d vector cases", failures, cases_run);
    end

    initial begin
        #5000000;
        $fatal(1, "global simulation timeout");
    end
endmodule

`default_nettype wire
