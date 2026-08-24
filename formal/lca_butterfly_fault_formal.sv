// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module lca_butterfly_fault_formal (
    (* gclk *) input wire clk
);
    logic [2:0] step;

    wire rst_n = (step != 0);
    wire req_valid = (step == 1);
    wire req_ready;
    wire rsp_valid;
    wire rsp_ready = 1'b0;
    wire rsp_fault;
    wire [23:0] rsp_a;
    wire [23:0] rsp_b;

    // The old harness proved fail-closed behavior at one concrete value only:
    // ML-KEM req_a == q. Mutation testing found that a comparator accepting
    // q+2048 survived both simulation and this proof. Make the entire invalid
    // input space symbolic instead, while keeping the request constant for the
    // short scripted protocol proof.
    (* anyconst *) wire [1:0] req_modulus_id;
    (* anyconst *) wire [23:0] req_a;
    (* anyconst *) wire [23:0] req_b;
    (* anyconst *) wire [23:0] req_twiddle;

    wire [23:0] selected_modulus =
        (req_modulus_id == 2'd0) ? 24'd3329 :
        (req_modulus_id == 2'd1) ? 24'd8380417 : 24'd0;
    wire request_is_invalid =
        (req_modulus_id > 2'd1) ||
        (req_a >= selected_modulus) ||
        (req_b >= selected_modulus) ||
        (req_twiddle >= selected_modulus);

    always @* begin
        assume(request_is_invalid);
    end

    always @(posedge clk) begin
        if (step < 3'd4)
            step <= step + 1'b1;

        if (step == 1)
            assert(req_ready);
        if (step >= 2) begin
            assert(rsp_valid);
            assert(rsp_fault);
            assert(!req_ready);
            assert(rsp_a == 24'd0);
            assert(rsp_b == 24'd0);
        end
    end

    lca_butterfly dut (
        .clk,
        .rst_n,
        .req_valid,
        .req_ready,
        .req_modulus_id,
        .req_a,
        .req_b,
        .req_twiddle,
        .rsp_valid,
        .rsp_ready,
        .rsp_fault,
        .rsp_a,
        .rsp_b
    );
endmodule

`default_nettype wire
