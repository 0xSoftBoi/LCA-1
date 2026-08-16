// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
`default_nettype none

// Self-checking Icarus testbench for rtl/lca_modmul_fast.sv.
//
// Run:
//   iverilog -g2012 -Wall -s tb_lca_modmul_fast -o /tmp/simv_fast \
//       rtl/lca_modmul_fast.sv verification/tb_lca_modmul_fast.sv
//   vvp /tmp/simv_fast
//
// Checked here:
//   * directed and boundary vectors for both production moduli;
//   * seeded randomized vectors for both moduli;
//   * fail-closed behaviour for bad selectors and non-canonical operands;
//   * exact, data-independent latency on every accepted request - two clock
//     edges after the accepting edge, including for faulting ones;
//   * response stability under back-pressure;
//   * full-rate streaming: one result per clock, in order;
//   * no loss or reordering when the output stalls with the pipeline full;
//   * reset cancels an in-flight request and clears the outputs.
//
// The golden value is computed here with a 64-bit multiply and the simulator's
// own modulo, i.e. independently of the reduction under test.

module tb_lca_modmul_fast;
    localparam integer MAX_WAIT_CYCLES   = 32;
    // Clock edges from the accepting posedge to the posedge that asserts
    // rsp_valid, counted exactly the way verification/vectors/
    // butterfly_vectors.txt counts the shift-add slice's 24.
    localparam integer EXPECTED_LATENCY  = 2;
    // Registered stages, which is also the negedge-to-negedge offset between
    // driving a request and sampling its response (one more than
    // EXPECTED_LATENCY because stimulus is driven on the negedge before the
    // accepting posedge).
    localparam integer PIPELINE_DEPTH    = 3;
    localparam integer STREAM_LENGTH     = 256;
    localparam integer RANDOM_PER_MODULUS = 400;

    localparam [23:0] KEM_Q = 24'd3329;
    localparam [23:0] DSA_Q = 24'd8380417;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        req_valid = 1'b0;
    logic        req_ready;
    logic [1:0]  req_modulus_id = 2'd0;
    logic [23:0] req_a = 24'd0;
    logic [23:0] req_b = 24'd0;
    logic        rsp_valid;
    logic        rsp_ready = 1'b0;
    logic        rsp_fault;
    logic [23:0] rsp_product;

    integer failures = 0;
    integer cases_run = 0;
    integer rand_seed = 32'h1CA1_FA57;

    always #5 clk = ~clk;

    lca_modmul_fast dut (
        .clk, .rst_n,
        .req_valid, .req_ready, .req_modulus_id, .req_a, .req_b,
        .rsp_valid, .rsp_ready, .rsp_fault, .rsp_product
    );

    // ------------------------------------------------------------------ //
    // Independent golden model                                           //
    // ------------------------------------------------------------------ //

    function automatic [23:0] golden_modulus(input [1:0] modulus_id);
        golden_modulus = (modulus_id == 2'd0) ? KEM_Q :
                         (modulus_id == 2'd1) ? DSA_Q : 24'd0;
    endfunction

    function automatic golden_request_ok(
        input [1:0]  modulus_id,
        input [23:0] a,
        input [23:0] b
    );
        reg [23:0] q;
        begin
            q = golden_modulus(modulus_id);
            golden_request_ok = (modulus_id <= 2'd1) && (a < q) && (b < q);
        end
    endfunction

    function automatic [23:0] golden_product(
        input [1:0]  modulus_id,
        input [23:0] a,
        input [23:0] b
    );
        reg [63:0] wide;
        reg [63:0] q;
        begin
            if (!golden_request_ok(modulus_id, a, b)) begin
                golden_product = 24'd0;
            end else begin
                q = {40'd0, golden_modulus(modulus_id)};
                wide = {40'd0, a} * {40'd0, b};
                golden_product = (wide % q);
            end
        end
    endfunction

    function automatic [23:0] random_below(input [23:0] bound);
        reg [31:0] draw;
        begin
            draw = $random(rand_seed);
            random_below = draw % {8'd0, bound};
        end
    endfunction

    // ------------------------------------------------------------------ //
    // One request, measured latency, held response                       //
    // ------------------------------------------------------------------ //

    task automatic run_case(
        input integer     case_id,
        input [1:0]       modulus_id,
        input [23:0]      a,
        input [23:0]      b,
        input integer     hold_cycles
    );
        integer cycles;
        integer hold_index;
        reg [23:0] expected_product;
        reg        expected_fault;
        reg        held_fault;
        reg [23:0] held_product;
        begin
            expected_product = golden_product(modulus_id, a, b);
            expected_fault   = !golden_request_ok(modulus_id, a, b);

            @(negedge clk);
            while (!req_ready) @(negedge clk);

            req_modulus_id = modulus_id;
            req_a          = a;
            req_b          = b;
            req_valid      = 1'b1;

            // The accepting posedge falls between this negedge and the next
            // one, so `cycles` counts clock edges strictly after acceptance.
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
                if (cycles != EXPECTED_LATENCY) begin
                    $display("FAIL case=%0d latency got=%0d expected=%0d",
                             case_id, cycles, EXPECTED_LATENCY);
                    failures = failures + 1;
                end
                if (rsp_fault !== expected_fault ||
                    rsp_product !== expected_product) begin
                    $display(
                        "FAIL case=%0d qid=%0d a=%0d b=%0d got=(%0d,f=%0b) expected=(%0d,f=%0b)",
                        case_id, modulus_id, a, b,
                        rsp_product, rsp_fault, expected_product, expected_fault
                    );
                    failures = failures + 1;
                end

                held_fault   = rsp_fault;
                held_product = rsp_product;
                for (hold_index = 0; hold_index < hold_cycles;
                     hold_index = hold_index + 1) begin
                    @(negedge clk);
                    if (!rsp_valid || req_ready ||
                        rsp_fault !== held_fault ||
                        rsp_product !== held_product) begin
                        $display("FAIL case=%0d response changed under backpressure",
                                 case_id);
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

    // ------------------------------------------------------------------ //
    // Full-rate streaming: one accepted request and one response a clock //
    // ------------------------------------------------------------------ //

    reg [1:0]  stream_id      [0:STREAM_LENGTH-1];
    reg [23:0] stream_a       [0:STREAM_LENGTH-1];
    reg [23:0] stream_b       [0:STREAM_LENGTH-1];
    reg [23:0] stream_expect  [0:STREAM_LENGTH-1];
    reg        stream_fault   [0:STREAM_LENGTH-1];

    task automatic run_stream;
        integer index;
        integer issue;
        integer retire;
        begin
            for (index = 0; index < STREAM_LENGTH; index = index + 1) begin
                stream_id[index] = (index % 2 == 0) ? 2'd0 : 2'd1;
                stream_a[index]  = random_below(golden_modulus(stream_id[index]));
                stream_b[index]  = random_below(golden_modulus(stream_id[index]));
                stream_expect[index] =
                    golden_product(stream_id[index], stream_a[index], stream_b[index]);
                stream_fault[index] = 1'b0;
            end

            @(negedge clk);
            while (!req_ready) @(negedge clk);
            rsp_ready = 1'b1;

            for (index = 0; index < STREAM_LENGTH + PIPELINE_DEPTH;
                 index = index + 1) begin
                issue  = index;
                retire = index - PIPELINE_DEPTH;

                if (retire >= 0) begin
                    if (!rsp_valid) begin
                        $display("FAIL stream index=%0d expected a response", retire);
                        failures = failures + 1;
                    end else if (rsp_fault !== stream_fault[retire] ||
                                 rsp_product !== stream_expect[retire]) begin
                        $display(
                            "FAIL stream index=%0d qid=%0d a=%0d b=%0d got=(%0d,f=%0b) expected=(%0d,f=%0b)",
                            retire, stream_id[retire], stream_a[retire],
                            stream_b[retire], rsp_product, rsp_fault,
                            stream_expect[retire], stream_fault[retire]
                        );
                        failures = failures + 1;
                    end
                    cases_run = cases_run + 1;
                end

                if (issue < STREAM_LENGTH) begin
                    if (!req_ready) begin
                        $display("FAIL stream index=%0d back-pressured at full rate",
                                 issue);
                        failures = failures + 1;
                    end
                    req_valid      = 1'b1;
                    req_modulus_id = stream_id[issue];
                    req_a          = stream_a[issue];
                    req_b          = stream_b[issue];
                end else begin
                    req_valid = 1'b0;
                end

                @(negedge clk);
            end

            req_valid = 1'b0;
            rsp_ready = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ //
    // Stall a full pipeline, then drain it in order                      //
    // ------------------------------------------------------------------ //

    task automatic run_stall_and_drain;
        integer index;
        integer stall;
        reg [1:0]  ids   [0:2];
        reg [23:0] ops_a [0:2];
        reg [23:0] ops_b [0:2];
        reg [23:0] want  [0:2];
        begin
            ids[0] = 2'd0; ops_a[0] = 24'd3328; ops_b[0] = 24'd3328;
            ids[1] = 2'd1; ops_a[1] = 24'd8380416; ops_b[1] = 24'd8380416;
            ids[2] = 2'd2; ops_a[2] = 24'd7; ops_b[2] = 24'd9;
            for (index = 0; index < 3; index = index + 1)
                want[index] = golden_product(ids[index], ops_a[index], ops_b[index]);

            rsp_ready = 1'b0;
            @(negedge clk);
            while (!req_ready) @(negedge clk);

            for (index = 0; index < 3; index = index + 1) begin
                if (!req_ready) begin
                    $display("FAIL drain: pipeline refused request %0d", index);
                    failures = failures + 1;
                end
                req_valid      = 1'b1;
                req_modulus_id = ids[index];
                req_a          = ops_a[index];
                req_b          = ops_b[index];
                @(negedge clk);
            end
            req_valid = 1'b0;

            // The first result is now presented and unaccepted, so the whole
            // pipeline must freeze: req_ready low, nothing lost.
            for (stall = 0; stall < 8; stall = stall + 1) begin
                if (!rsp_valid || req_ready) begin
                    $display("FAIL drain: pipeline did not freeze at stall %0d", stall);
                    failures = failures + 1;
                end
                @(negedge clk);
            end

            rsp_ready = 1'b1;
            for (index = 0; index < 3; index = index + 1) begin
                if (!rsp_valid) begin
                    $display("FAIL drain: missing response %0d", index);
                    failures = failures + 1;
                end else if (rsp_fault !== (ids[index] > 2'd1) ||
                             rsp_product !== want[index]) begin
                    $display(
                        "FAIL drain index=%0d got=(%0d,f=%0b) expected=(%0d,f=%0b)",
                        index, rsp_product, rsp_fault, want[index],
                        (ids[index] > 2'd1)
                    );
                    failures = failures + 1;
                end
                cases_run = cases_run + 1;
                @(negedge clk);
            end
            rsp_ready = 1'b0;
            if (rsp_valid) begin
                $display("FAIL drain: pipeline still holds a response");
                failures = failures + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------ //
    // Reset cancellation                                                 //
    // ------------------------------------------------------------------ //

    task automatic run_reset_cancellation;
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_modulus_id = 2'd1;
            req_a          = 24'd1234567;
            req_b          = 24'd7654321;
            req_valid      = 1'b1;
            @(negedge clk);
            req_valid = 1'b0;

            rst_n = 1'b0;
            @(negedge clk);
            if (rsp_valid || rsp_fault || rsp_product !== 24'd0) begin
                $display("FAIL reset did not cancel and clear the in-flight request");
                failures = failures + 1;
            end
            rst_n = 1'b1;
            @(negedge clk);
            if (!req_ready) begin
                $display("FAIL interface did not recover after reset");
                failures = failures + 1;
            end
            cases_run = cases_run + 1;
        end
    endtask

    // ------------------------------------------------------------------ //
    // Stimulus                                                           //
    // ------------------------------------------------------------------ //

    integer i;
    integer j;
    integer case_id;
    reg [23:0] kem_edges [0:7];
    reg [23:0] dsa_edges [0:9];
    reg [23:0] ra;
    reg [23:0] rb;

    initial begin
        kem_edges[0] = 24'd0;
        kem_edges[1] = 24'd1;
        kem_edges[2] = 24'd2;
        kem_edges[3] = 24'd255;
        kem_edges[4] = 24'd256;
        kem_edges[5] = 24'd257;
        kem_edges[6] = 24'd3327;
        kem_edges[7] = 24'd3328;

        dsa_edges[0] = 24'd0;
        dsa_edges[1] = 24'd1;
        dsa_edges[2] = 24'd2;
        dsa_edges[3] = 24'd8191;
        dsa_edges[4] = 24'd8192;
        dsa_edges[5] = 24'd8193;
        dsa_edges[6] = 24'd4194304;
        dsa_edges[7] = 24'd8380415;
        dsa_edges[8] = 24'd8380416;
        dsa_edges[9] = 24'd4190208;

        case_id = 0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Directed and boundary: every ordered pair of edge operands.
        for (i = 0; i < 8; i = i + 1)
            for (j = 0; j < 8; j = j + 1) begin
                run_case(case_id, 2'd0, kem_edges[i], kem_edges[j],
                         ((i + j) % 5 == 0) ? 3 : 0);
                case_id = case_id + 1;
            end

        for (i = 0; i < 10; i = i + 1)
            for (j = 0; j < 10; j = j + 1) begin
                run_case(case_id, 2'd1, dsa_edges[i], dsa_edges[j],
                         ((i + j) % 7 == 0) ? 4 : 0);
                case_id = case_id + 1;
            end

        // Fail-closed: bad selector, and non-canonical operands for each
        // supported modulus.
        run_case(case_id, 2'd2, 24'd1, 24'd1, 2); case_id = case_id + 1;
        run_case(case_id, 2'd3, 24'd0, 24'd0, 0); case_id = case_id + 1;
        run_case(case_id, 2'd0, 24'd3329, 24'd0, 0); case_id = case_id + 1;
        run_case(case_id, 2'd0, 24'd0, 24'd3329, 0); case_id = case_id + 1;
        run_case(case_id, 2'd0, 24'd8380416, 24'd1, 3); case_id = case_id + 1;
        run_case(case_id, 2'd1, 24'd8380417, 24'd0, 0); case_id = case_id + 1;
        run_case(case_id, 2'd1, 24'd0, 24'd8380417, 0); case_id = case_id + 1;
        run_case(case_id, 2'd1, 24'hFFFFFF, 24'hFFFFFF, 0); case_id = case_id + 1;

        // Seeded randomized vectors for both moduli.
        for (i = 0; i < RANDOM_PER_MODULUS; i = i + 1) begin
            ra = random_below(KEM_Q);
            rb = random_below(KEM_Q);
            run_case(case_id, 2'd0, ra, rb, (i % 37 == 0) ? 2 : 0);
            case_id = case_id + 1;
        end
        for (i = 0; i < RANDOM_PER_MODULUS; i = i + 1) begin
            ra = random_below(DSA_Q);
            rb = random_below(DSA_Q);
            run_case(case_id, 2'd1, ra, rb, (i % 41 == 0) ? 2 : 0);
            case_id = case_id + 1;
        end

        run_stream();
        run_stall_and_drain();
        run_reset_cancellation();

        if (failures == 0) begin
            $display(
                "PASS lca_modmul_fast checks=%0d latency=%0d cycles stages=%0d stream=%0d seed=%0h",
                cases_run, EXPECTED_LATENCY, PIPELINE_DEPTH, STREAM_LENGTH,
                32'h1CA1_FA57
            );
            $finish;
        end
        $fatal(1, "%0d failures across %0d checks", failures, cases_run);
    end

    initial begin
        #5000000;
        $fatal(1, "global simulation timeout");
    end
endmodule

`default_nettype wire
