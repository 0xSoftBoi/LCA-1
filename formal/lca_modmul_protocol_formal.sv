// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module lca_modmul_protocol_formal (
    (* gclk *) input wire clk
);
    localparam integer WORD_BITS = 24;

    logic [5:0] step;
    logic response_seen;
    logic [WORD_BITS-1:0] held_product;

    wire rst_n = (step != 0);
    wire req_valid = (step == 1);
    wire req_ready;
    wire rsp_valid;
    wire rsp_ready = 1'b0;
    wire [WORD_BITS-1:0] rsp_product;

    always @(posedge clk) begin
        if (step < 6'd28)
            step <= step + 1'b1;

        if (!rst_n) begin
            response_seen <= 1'b0;
            held_product <= '0;
        end else if (rsp_valid && !response_seen) begin
            response_seen <= 1'b1;
            held_product <= rsp_product;
        end

        if (step == 1)
            assert(req_ready);
        if (step >= 2 && step < 26) begin
            assert(!req_ready);
            assert(!rsp_valid);
        end
        if (step >= 26) begin
            assert(rsp_valid);
            assert(!req_ready);
            assert(rsp_product == 24'd6);
        end
        if (response_seen) begin
            assert(rsp_valid);
            assert(rsp_product == held_product);
        end
    end

    lca_modmul #(.WORD_BITS(WORD_BITS)) dut (
        .clk,
        .rst_n,
        .req_valid,
        .req_ready,
        .req_a(24'd2),
        .req_b(24'd3),
        .req_modulus(24'd3329),
        .rsp_valid,
        .rsp_ready,
        .rsp_product
    );
endmodule

`default_nettype wire
