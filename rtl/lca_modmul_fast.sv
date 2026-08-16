// SPDX-License-Identifier: Apache-2.0
`default_nettype none

// Fast, branch-free, fixed-latency modular multiplier for the two LCA-1
// production moduli. This module runs *beside* rtl/lca_modmul.sv, which stays
// the bit-serial reference and the only claims-bearing multiplier; nothing
// here replaces it and nothing here is in the E1 evidence chain yet
// (see docs/FAST_REDUCTION.md).
//
// Executable specification: model/fastmod.py (exhaustively checked for
// q=3329 over the complete 2**24 product domain).
//
// Arithmetic
// ----------
// ML-KEM, q = 3329 = 13*2**8 + 1 (Proth form q = k*2**m + 1), K-RED:
//
//     C = C1*2**m + C0,  C0 = C mod 2**m,  C1 = C >>> m
//     KRED(C) = k*C0 - C1 = k*C - q*C1        (exact integer identity)
//             == k*C  (mod q)
//
//   K2RED = KRED(KRED(.)) scales by k**2 = 169. Two K2RED chains separated by
//   a multiply by the constant 1353 give an exact result, because
//   169**2 * 1353 == 1 (mod 3329):
//
//     X = norm(K2RED(a*b))        == 169*a*b     (mod q),  X in [0,q)
//     Y = norm(K2RED(X*1353))     == a*b         (mod q),  Y in [0,q)
//
//   Proven ranges: KRED maps [0,2**24) into [-65535,3315]; a second KRED maps
//   that into [-12,3571]; norm() adds q (giving [3317,6900] < 3*q) and applies
//   two conditional subtracts, landing in [0,q). Both K2RED inputs are below
//   2**24 by construction: a*b <= 3328**2 = 11075584, and X*1353 <= 4502784.
//
// ML-DSA, q = 8380417 = 2**23 - 2**13 + 1 (Solinas), so 2**23 == 2**13 - 1:
//
//     C = C1*2**23 + C0
//     fold(C) = C0 + (C1 << 13) - C1 = C - q*C1  (exact integer identity)
//             == C  (mod q),  and fold(C) >= 0 for C >= 0
//
//   Four folds take a product below 2**46 through the exact worst cases
//   68719468544 < 2**36, 75472897 < 2**27, 8445944 < 2**24 and 8388607 <
//   2**23. Since 8388607 < 2*q, one conditional subtract lands in [0,q).
//   All internal signals are carried at 48 bits, so the same bound chain
//   holds for a completely unconstrained 48-bit stage input as well - that is
//   what makes the output-range assertions below 1-inductive.
//
// Timing and control
// ------------------
// Three registered stages, one result per clock, and a fixed latency: for a
// request accepted on clock edge N, rsp_valid asserts on edge N+2. That is the
// same measurement convention as the 24 recorded for the shift-add slice in
// verification/vectors/butterfly_vectors.txt. There is no data-dependent
// control anywhere in the datapath: every conditional is a 2:1 mux driven by a
// subtractor borrow bit or by the (public) modulus selector. Faulting requests
// take exactly the same two cycles and return a zero product.
//
// Constant-time here is a structural property of the algorithm. This module
// carries no timing, power or electromagnetic side-channel claim.

module lca_modmul_fast #(
    // The reductions are specialised to the two 24-bit production moduli;
    // WORD_BITS exists to match the port style of rtl/lca_modmul.sv and must
    // be 24.
    parameter int WORD_BITS = 24
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic [1:0]           req_modulus_id,
    input  logic [WORD_BITS-1:0] req_a,
    input  logic [WORD_BITS-1:0] req_b,

    output logic                 rsp_valid,
    input  logic                 rsp_ready,
    output logic                 rsp_fault,
    output logic [WORD_BITS-1:0] rsp_product
);

    localparam int PROD_BITS = 2 * WORD_BITS;

    localparam logic [WORD_BITS-1:0] KEM_Q = 24'd3329;
    localparam logic [WORD_BITS-1:0] DSA_Q = 24'd8380417;
    localparam logic [PROD_BITS-1:0] DSA_Q_WIDE = 48'd8380417;

    // ---------------------------------------------------------------- //
    // Reduction primitives                                             //
    // ---------------------------------------------------------------- //

    // One K-RED fold: 13*C0 - C1 with an arithmetic shift, so it is also
    // correct for the negative intermediate produced by the first fold.
    // 13*x is (x<<3) + (x<<2) + x; no multiplier is required.
    function automatic logic signed [31:0] kred(input logic signed [31:0] value);
        kred = (32'sd13 * $signed({24'd0, value[7:0]})) - (value >>> 8);
    endfunction

    // Map [-12, 3571] into [0, 3329) with two branch-free conditional
    // subtracts. The select is the sign bit of the subtractor result, i.e.
    // the borrow, so this is a subtractor plus a 2:1 mux per stage.
    // The return width is deliberately wider than the proven range so that a
    // range assertion on the result cannot be satisfied by truncation.
    function automatic logic signed [31:0] kem_normalize(
        input logic signed [31:0] value
    );
        logic signed [31:0] shifted;
        logic signed [31:0] difference;
        begin
            shifted    = value + 32'sd3329;
            difference = shifted - 32'sd3329;
            shifted    = difference[31] ? shifted : difference;
            difference = shifted - 32'sd3329;
            shifted    = difference[31] ? shifted : difference;
            kem_normalize = shifted;
        end
    endfunction

    // norm(K2RED(C)): canonical in [0, q) and congruent to 169*C mod q.
    // Requires C < 2**24, which both call sites guarantee structurally.
    function automatic logic signed [31:0] kred2_norm(input logic [23:0] value);
        kred2_norm = kem_normalize(kred(kred($signed({8'd0, value}))));
    endfunction

    // One Solinas fold for q = 2**23 - 2**13 + 1. Both terms are
    // non-negative, so no sign handling is needed.
    function automatic logic [PROD_BITS-1:0] dsa_fold(
        input logic [PROD_BITS-1:0] value
    );
        logic [PROD_BITS-1:0] low;
        logic [PROD_BITS-1:0] high;
        begin
            low      = {25'd0, value[22:0]};
            high     = value >> 23;
            dsa_fold = low + (high << 13) - high;
        end
    endfunction

    // Final conditional subtract for the ML-DSA path. The incoming value is
    // below 2**23 < 2*q, so one subtract suffices; the select is the borrow.
    // Full-width return, for the same anti-truncation reason as
    // kem_normalize above.
    function automatic logic [PROD_BITS-1:0] dsa_final(
        input logic [PROD_BITS-1:0] value
    );
        logic [PROD_BITS-1:0] difference;
        begin
            difference = value - DSA_Q_WIDE;
            dsa_final  = difference[PROD_BITS-1] ? value : difference;
        end
    endfunction

    // ---------------------------------------------------------------- //
    // Stage A: fail-closed input check and the single wide multiply     //
    // ---------------------------------------------------------------- //

    logic [WORD_BITS-1:0] selected_modulus;
    logic                 request_is_kem;
    logic                 request_ok;
    logic [WORD_BITS-1:0] operand_a;
    logic [WORD_BITS-1:0] operand_b;
    logic [PROD_BITS-1:0] stage_a_product;

    always_comb begin
        case (req_modulus_id)
            2'd0:    selected_modulus = KEM_Q;
            2'd1:    selected_modulus = DSA_Q;
            default: selected_modulus = '0;
        endcase
        request_is_kem = (req_modulus_id == 2'd0);
        // Fail closed: an unsupported selector or a non-canonical operand
        // never reaches the datapath. The operands are forced to zero so no
        // out-of-range value can propagate into the reduction, and the
        // response still takes exactly the same number of cycles as a
        // successful one.
        request_ok = (req_modulus_id <= 2'd1) &&
                     (req_a < selected_modulus) &&
                     (req_b < selected_modulus);
        operand_a = request_ok ? req_a : '0;
        operand_b = request_ok ? req_b : '0;
        stage_a_product = {{WORD_BITS{1'b0}}, operand_a} *
                          {{WORD_BITS{1'b0}}, operand_b};
    end

    // ---------------------------------------------------------------- //
    // Pipeline registers                                               //
    // ---------------------------------------------------------------- //

    logic                 stage1_valid;
    logic                 stage1_fault;
    logic                 stage1_kem;
    logic [PROD_BITS-1:0] stage1_product;

    logic                 stage2_valid;
    logic                 stage2_fault;
    logic                 stage2_kem;
    logic [PROD_BITS-1:0] stage2_data;

    // The whole pipeline advances together, so an unaccepted response stalls
    // every stage and req_ready drops. That keeps the latency fixed for every
    // accepted request, stalls included, and keeps the control state small
    // enough to prove by induction.
    logic pipeline_advance;
    assign pipeline_advance = !rsp_valid || rsp_ready;
    assign req_ready        = pipeline_advance;

    // ---------------------------------------------------------------- //
    // Stage B: first reduction round                                   //
    // ---------------------------------------------------------------- //

    logic signed [31:0]   stage_b_kem;
    logic [PROD_BITS-1:0] stage_b_dsa;
    logic [PROD_BITS-1:0] stage_b_data;

    // ML-KEM: X = norm(K2RED(a*b)) == 169*a*b (mod q), X in [0,q).
    assign stage_b_kem  = kred2_norm(stage1_product[23:0]);
    // ML-DSA: folds 1 and 2 of 4.
    assign stage_b_dsa  = dsa_fold(dsa_fold(stage1_product));
    assign stage_b_data = stage1_kem ? {{(PROD_BITS-12){1'b0}}, stage_b_kem[11:0]}
                                     : stage_b_dsa;

    // ---------------------------------------------------------------- //
    // Stage C: second reduction round and canonical output             //
    // ---------------------------------------------------------------- //

    logic [23:0]          stage_c_scaled;
    logic signed [31:0]   stage_c_kem;
    logic [PROD_BITS-1:0] stage_c_dsa;
    logic [WORD_BITS-1:0] stage_c_result;

    // 1353 = 2**10 + 2**8 + 2**6 + 2**3 + 2**0, so this is a five-term
    // shift-add, and the product is below 2**24 for any 12-bit input.
    assign stage_c_scaled = {12'd0, stage2_data[11:0]} * 24'd1353;
    assign stage_c_kem    = kred2_norm(stage_c_scaled);
    // ML-DSA: folds 3 and 4 of 4, then the single conditional subtract.
    assign stage_c_dsa    = dsa_final(dsa_fold(dsa_fold(stage2_data)));
    assign stage_c_result = stage2_kem ? {{(WORD_BITS-12){1'b0}}, stage_c_kem[11:0]}
                                       : stage_c_dsa[WORD_BITS-1:0];

    // ---------------------------------------------------------------- //
    // Sequential control                                               //
    // ---------------------------------------------------------------- //

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stage1_valid   <= 1'b0;
            stage1_fault   <= 1'b0;
            stage1_kem     <= 1'b0;
            stage1_product <= '0;
            stage2_valid   <= 1'b0;
            stage2_fault   <= 1'b0;
            stage2_kem     <= 1'b0;
            stage2_data    <= '0;
            rsp_valid      <= 1'b0;
            rsp_fault      <= 1'b0;
            rsp_product    <= '0;
        end else if (pipeline_advance) begin
            stage1_valid   <= req_valid;
            stage1_fault   <= !request_ok;
            stage1_kem     <= request_is_kem;
            stage1_product <= stage_a_product;

            stage2_valid   <= stage1_valid;
            stage2_fault   <= stage1_fault;
            stage2_kem     <= stage1_kem;
            stage2_data    <= stage_b_data;

            rsp_valid      <= stage2_valid;
            rsp_fault      <= stage2_fault;
            rsp_product    <= stage2_fault ? '0 : stage_c_result;
        end
    end

`ifdef FORMAL
    // Unbounded invariants, proven by temporal induction with every input
    // unconstrained on every cycle (see formal/lca_modmul_fast_formal.ys).
    // The set is 1-inductive, so the properties hold at all times, not up to
    // a bound.
    //
    // Protocol
    //   P1  req_ready is exactly the pipeline-advance condition;
    //   P2  an unaccepted response holds valid with identical fault flag and
    //       product across any cycle in which reset stays deasserted (reset
    //       legitimately cancels a pending response, so P2 is conditioned on
    //       it);
    //   P3  back-pressure freezes the pipeline: while a response is stalled,
    //       no stage register changes, so no in-flight request is dropped or
    //       corrupted and the fixed latency is preserved across stalls;
    //   P4  a faulting response carries a zero product - fail closed.
    //
    // Arithmetic (full width, all stage registers unconstrained)
    //   A1  the ML-KEM stage-B result is canonical for q=3329, for every one
    //       of the 2**24 possible stage-1 product low words;
    //   A2  the ML-KEM stage-C result is canonical for q=3329, for every
    //       possible 12-bit stage-2 payload;
    //   A3  the ML-DSA stage-C result is canonical for q=8380417, for every
    //       one of the 2**48 possible stage-2 payloads - i.e. the four-fold
    //       Solinas bound chain is proven at full width, not sampled;
    //   A4  the registered product is canonical for the selected modulus.
    //
    // A1-A3 are range proofs, not equivalence proofs: congruence to a*b mod q
    // is evidence from model/fastmod.py (exhaustive for q=3329) and from the
    // testbench, not from this block. See docs/FAST_REDUCTION.md.
    //
    // This block is invisible to synthesis and simulation; only the formal
    // flow defines FORMAL.
    reg                 f_past_valid = 1'b0;
    reg                 f_past_rst_n = 1'b0;
    reg                 f_past_rsp_valid = 1'b0;
    reg                 f_past_rsp_ready = 1'b0;
    reg                 f_past_rsp_fault = 1'b0;
    reg [WORD_BITS-1:0] f_past_rsp_product = '0;
    reg                 f_past_stage1_valid = 1'b0;
    reg                 f_past_stage1_fault = 1'b0;
    reg                 f_past_stage1_kem = 1'b0;
    reg [PROD_BITS-1:0] f_past_stage1_product = '0;
    reg                 f_past_stage2_valid = 1'b0;
    reg                 f_past_stage2_fault = 1'b0;
    reg                 f_past_stage2_kem = 1'b0;
    reg [PROD_BITS-1:0] f_past_stage2_data = '0;

    // Formal-only mirror of the modulus selector that produced the response
    // currently in the output register, so A4 can state the tighter ML-KEM
    // bound. Updated with exactly the output register's enable.
    reg                 f_rsp_kem = 1'b0;

    always @(posedge clk) begin
        if (!rst_n)
            f_rsp_kem <= 1'b0;
        else if (pipeline_advance)
            f_rsp_kem <= stage2_kem;
    end

    always @(posedge clk) begin
        f_past_valid          <= 1'b1;
        f_past_rst_n          <= rst_n;
        f_past_rsp_valid      <= rsp_valid;
        f_past_rsp_ready      <= rsp_ready;
        f_past_rsp_fault      <= rsp_fault;
        f_past_rsp_product    <= rsp_product;
        f_past_stage1_valid   <= stage1_valid;
        f_past_stage1_fault   <= stage1_fault;
        f_past_stage1_kem     <= stage1_kem;
        f_past_stage1_product <= stage1_product;
        f_past_stage2_valid   <= stage2_valid;
        f_past_stage2_fault   <= stage2_fault;
        f_past_stage2_kem     <= stage2_kem;
        f_past_stage2_data    <= stage2_data;
    end

    always @* begin
        // P1
        assert(req_ready == (!rsp_valid || rsp_ready));
        // P4
        if (rsp_fault)
            assert(rsp_product == '0);
        // A1 - A3, asserted on the untruncated function results
        assert(stage_b_kem >= 32'sd0 && stage_b_kem < 32'sd3329);
        assert(stage_c_kem >= 32'sd0 && stage_c_kem < 32'sd3329);
        assert(stage_c_dsa < DSA_Q_WIDE);
        // A4
        if (rsp_valid && !rsp_fault) begin
            assert(rsp_product < DSA_Q);
            if (f_rsp_kem)
                assert(rsp_product < KEM_Q);
        end
        if (f_past_valid && f_past_rst_n && rst_n &&
            f_past_rsp_valid && !f_past_rsp_ready) begin
            // P2
            assert(rsp_valid);
            assert(rsp_fault == f_past_rsp_fault);
            assert(rsp_product == f_past_rsp_product);
            // P3
            assert(stage1_valid   == f_past_stage1_valid);
            assert(stage1_fault   == f_past_stage1_fault);
            assert(stage1_kem     == f_past_stage1_kem);
            assert(stage1_product == f_past_stage1_product);
            assert(stage2_valid   == f_past_stage2_valid);
            assert(stage2_fault   == f_past_stage2_fault);
            assert(stage2_kem     == f_past_stage2_kem);
            assert(stage2_data    == f_past_stage2_data);
        end
    end
`endif

endmodule

`default_nettype wire
