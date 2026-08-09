`default_nettype none

module lca_modmul_arithmetic_formal (
    (* gclk *) input wire clk
);
    localparam integer WORD_BITS = 4;
    localparam logic [WORD_BITS-1:0] Q = 4'd13;

    logic [3:0] step;

    (* anyconst *) wire [WORD_BITS-1:0] symbolic_a;
    (* anyconst *) wire [WORD_BITS-1:0] symbolic_b;

    wire rst_n = (step != 0);
    wire req_valid = (step == 1);
    wire req_ready;
    wire rsp_valid;
    wire rsp_ready = 1'b0;
    wire [WORD_BITS-1:0] rsp_product;
    wire [(2*WORD_BITS)-1:0] expected_wide = symbolic_a * symbolic_b;
    wire [WORD_BITS-1:0] expected = expected_wide % Q;

    always @* begin
        assume(symbolic_a < Q);
        assume(symbolic_b < Q);
    end

    always @(posedge clk) begin
        if (step < 4'd7)
            step <= step + 1'b1;

        if (step == 1)
            assert(req_ready);
        if (step >= 2 && step < 6) begin
            assert(!req_ready);
            assert(!rsp_valid);
        end
        if (step >= 6) begin
            assert(rsp_valid);
            assert(!req_ready);
            assert(rsp_product == expected);
        end
    end

    lca_modmul #(.WORD_BITS(WORD_BITS)) dut (
        .clk,
        .rst_n,
        .req_valid,
        .req_ready,
        .req_a(symbolic_a),
        .req_b(symbolic_b),
        .req_modulus(Q),
        .rsp_valid,
        .rsp_ready,
        .rsp_product
    );
endmodule

`default_nettype wire
