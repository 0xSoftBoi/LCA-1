// SPDX-License-Identifier: Apache-2.0
//
// Survivor prober: drives the unmutated netlist (`gold`) and one mutant
// (`gate`) with identical stimulus and reports the first cycle at which any
// output differs.
//
// The point is not to detect the mutant - `test_eq` already decided whether a
// difference exists. The point is to identify WHICH stimulus dimension is
// needed, by re-running the same search under a ladder of profiles that
// switch individual dimensions on:
//
//   0 corpus     what tools/gen_vectors.py actually generates today: one
//                request in flight, canonical operands plus the eight
//                malformed patterns, response held 0-3 cycles, reset only at
//                time zero
//   1 +hold      same, but response backpressure up to 40 cycles
//   2 +offer     same as 0, but req_valid may be asserted while the slice is
//                busy or while a response is pending
//   3 +operands  same as 0, but operands and modulus_id are drawn from the
//                full input space, not just canonical values and the eight
//                malformed patterns
//   4 +reset     same as 0, but rst_n may be pulsed mid-transaction
//   5 all        every dimension at once
//
// The lowest profile that separates gold from gate names the exact generator
// change that would kill the mutant. Profile 0 must never separate them: the
// corpus already ran and did not.
//
// Usage: vvp -n sim +profile=N +seed=S +cycles=C

`timescale 1ns/1ps
`default_nettype none

module tb_probe;
    localparam [23:0] KEM_Q = 24'd3329;
    localparam [23:0] DSA_Q = 24'd8380417;

    integer profile = 0;
    integer seed    = 1;
    integer cycles  = 200000;

    logic        clk = 1'b0;
    logic        rst_n = 1'b0;
    logic        req_valid = 1'b0;
    logic [1:0]  req_modulus_id = 2'd0;
    logic [23:0] req_a = '0;
    logic [23:0] req_b = '0;
    logic [23:0] req_twiddle = '0;
    logic        rsp_ready = 1'b0;

    wire         g_req_ready, g_rsp_valid, g_rsp_fault;
    wire [23:0]  g_rsp_a, g_rsp_b;
    wire         m_req_ready, m_rsp_valid, m_rsp_fault;
    wire [23:0]  m_rsp_a, m_rsp_b;

    // Dimension enables, derived from the profile.
    logic allow_long_hold, allow_offer_while_busy, allow_full_operands;
    logic allow_mid_reset;

    integer cyc = 0;
    integer hold_target = 0;
    integer hold_count = 0;
    integer reset_left = 0;
    integer outstanding = 0;
    integer strict_cycle = -1;
    integer qual_cycle = -1;
    logic   skip = 1'b0;
    logic   req_ready_pre = 1'b0;

    always #5 clk = ~clk;

    gold u_gold (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(g_req_ready),
        .req_modulus_id(req_modulus_id),
        .req_a(req_a), .req_b(req_b), .req_twiddle(req_twiddle),
        .rsp_valid(g_rsp_valid), .rsp_ready(rsp_ready),
        .rsp_fault(g_rsp_fault), .rsp_a(g_rsp_a), .rsp_b(g_rsp_b)
    );

    gate u_gate (
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_ready(m_req_ready),
        .req_modulus_id(req_modulus_id),
        .req_a(req_a), .req_b(req_b), .req_twiddle(req_twiddle),
        .rsp_valid(m_rsp_valid), .rsp_ready(rsp_ready),
        .rsp_fault(m_rsp_fault), .rsp_a(m_rsp_a), .rsp_b(m_rsp_b)
    );

    function automatic [23:0] modulus_of(input [1:0] id);
        case (id)
            2'd0: modulus_of = KEM_Q;
            2'd1: modulus_of = DSA_Q;
            default: modulus_of = 24'd0;
        endcase
    endfunction

    // Operand distribution for the corpus-shaped profiles: canonical values
    // with the boundary cases the generator emits, plus the malformed
    // "operand == modulus" pattern the generator also emits.
    task automatic pick_request;
        integer pick;
        logic [23:0] q;
        begin
            if (allow_full_operands) begin
                req_modulus_id = $random(seed);
                req_a       = {$random(seed)} % 24'hFF_FFFF;
                req_b       = {$random(seed)} % 24'hFF_FFFF;
                req_twiddle = {$random(seed)} % 24'hFF_FFFF;
            end else begin
                pick = {$random(seed)} % 32;
                if (pick == 0) begin
                    // malformed: unsupported modulus selector
                    req_modulus_id = (({$random(seed)} % 2) == 0) ? 2'd2 : 2'd3;
                    req_a = '0; req_b = '0; req_twiddle = '0;
                end else begin
                    req_modulus_id = ({$random(seed)} % 2);
                    q = modulus_of(req_modulus_id);
                    req_a       = {$random(seed)} % q;
                    req_b       = {$random(seed)} % q;
                    req_twiddle = {$random(seed)} % q;
                    case ({$random(seed)} % 12)
                        0: req_a = '0;
                        1: req_b = '0;
                        2: req_twiddle = '0;
                        3: req_a = q - 24'd1;
                        4: req_b = q - 24'd1;
                        5: req_twiddle = q - 24'd1;
                        // malformed: operand exactly equal to the modulus
                        6: req_a = q;
                        7: req_b = q;
                        8: req_twiddle = q;
                        default: ;
                    endcase
                end
            end
        end
    endtask

    // Two notions of difference, reported separately:
    //
    //   strict     any output differs in any cycle - the notion test_eq's
    //              $equiv miter uses
    //   qualified  a difference the interface contract can actually observe:
    //              req_ready and rsp_valid always, and rsp_fault/rsp_a/rsp_b
    //              only in cycles where the response is valid
    //
    // strict-but-not-qualified means the mutant only perturbs the response
    // data bus while no response is being offered. The corpus is right not to
    // catch that, and it is not a corpus gap.
    task automatic check_outputs;
        begin
            if (rst_n === 1'b1) begin
                if (strict_cycle < 0 &&
                    ({g_req_ready, g_rsp_valid, g_rsp_fault, g_rsp_a, g_rsp_b} !==
                     {m_req_ready, m_rsp_valid, m_rsp_fault, m_rsp_a, m_rsp_b}))
                    strict_cycle = cyc;

                if (qual_cycle < 0 &&
                    ((g_req_ready !== m_req_ready) ||
                     (g_rsp_valid !== m_rsp_valid) ||
                     (g_rsp_valid === 1'b1 &&
                      ({g_rsp_fault, g_rsp_a, g_rsp_b} !==
                       {m_rsp_fault, m_rsp_a, m_rsp_b})))) begin
                    qual_cycle = cyc;
                    $display("  observable difference at cycle %0d", cyc);
                    $display("    stimulus rst_n=%b req_valid=%b id=%0d a=%0d b=%0d w=%0d rsp_ready=%b",
                             rst_n, req_valid, req_modulus_id, req_a, req_b,
                             req_twiddle, rsp_ready);
                    $display("    gold req_ready=%b rsp_valid=%b fault=%b a=%0d b=%0d",
                             g_req_ready, g_rsp_valid, g_rsp_fault, g_rsp_a, g_rsp_b);
                    $display("    gate req_ready=%b rsp_valid=%b fault=%b a=%0d b=%0d",
                             m_req_ready, m_rsp_valid, m_rsp_fault, m_rsp_a, m_rsp_b);
                end
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("profile=%d", profile)) profile = 0;
        if (!$value$plusargs("seed=%d", seed))       seed = 1;
        if (!$value$plusargs("cycles=%d", cycles))   cycles = 200000;

        allow_long_hold        = (profile == 1) || (profile == 5);
        allow_offer_while_busy = (profile == 2) || (profile == 5);
        allow_full_operands    = (profile == 3) || (profile == 5);
        allow_mid_reset        = (profile == 4) || (profile == 5);

        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        while (cyc < cycles && qual_cycle < 0) begin
            @(negedge clk);
            cyc = cyc + 1;

            skip = 1'b0;

            if (reset_left > 0) begin
                reset_left = reset_left - 1;
                rst_n = 1'b0;
                req_valid = 1'b0;
                rsp_ready = 1'b0;
                outstanding = 0;
                hold_count = 0;
                @(posedge clk);
                check_outputs();
                if (reset_left == 0) rst_n = 1'b1;
                skip = 1'b1;
            end else if (allow_mid_reset && (({$random(seed)} % 512) == 0)) begin
                reset_left = 1 + ({$random(seed)} % 3);
                skip = 1'b1;
            end

            if (!skip) begin
            // request side
            if (allow_offer_while_busy) begin
                if (({$random(seed)} % 4) == 0) begin
                    pick_request();
                    req_valid = 1'b1;
                end
            end else if (!req_valid && outstanding == 0 && g_req_ready) begin
                pick_request();
                req_valid = 1'b1;
            end

            // response side
            if (g_rsp_valid) begin
                if (hold_count == 0)
                    hold_target = allow_long_hold ? ({$random(seed)} % 41)
                                                  : ({$random(seed)} % 4);
                if (hold_count >= hold_target) begin
                    rsp_ready = 1'b1;
                    hold_count = 0;
                    outstanding = 0;
                end else begin
                    rsp_ready = 1'b0;
                    hold_count = hold_count + 1;
                end
            end else begin
                rsp_ready = 1'b0;
                hold_count = 0;
            end

            req_ready_pre = g_req_ready;
            @(posedge clk);
            check_outputs();

            // A request offered while the slice was ready has now been
            // accepted: drop req_valid so profile 0 issues exactly one
            // request at a time, the way the corpus driver does.
            if (req_valid && req_ready_pre) begin
                req_valid = 1'b0;
                outstanding = 1;
            end
            end
        end

        if (qual_cycle < 0) begin
            if (strict_cycle < 0)
                $display("SAME profile=%0d cycles=%0d seed=%0d", profile, cyc, seed);
            else
                $display("DONTCARE profile=%0d cycles=%0d seed=%0d first_strict_cycle=%0d",
                         profile, cyc, seed, strict_cycle);
        end else begin
            $display("DIFF profile=%0d cycle=%0d seed=%0d", profile, qual_cycle, seed);
        end
        $finish;
    end
endmodule

`default_nettype wire
