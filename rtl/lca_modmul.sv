// SPDX-License-Identifier: Apache-2.0
`default_nettype none

module lca_modmul #(
    parameter int WORD_BITS = 24
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic [WORD_BITS-1:0] req_a,
    input  logic [WORD_BITS-1:0] req_b,
    input  logic [WORD_BITS-1:0] req_modulus,

    output logic                 rsp_valid,
    input  logic                 rsp_ready,
    output logic [WORD_BITS-1:0] rsp_product
);

    localparam int COUNT_BITS = $clog2(WORD_BITS);

    logic                    busy;
    logic [COUNT_BITS-1:0]    count;
    logic [WORD_BITS-1:0]     product;
    logic [WORD_BITS-1:0]     multiplicand;
    logic [WORD_BITS-1:0]     multiplier;
    logic [WORD_BITS-1:0]     modulus;
    logic [WORD_BITS-1:0]     product_next;
    logic [WORD_BITS-1:0]     multiplicand_next;

    function automatic logic [WORD_BITS-1:0] add_mod(
        input logic [WORD_BITS-1:0] x,
        input logic [WORD_BITS-1:0] y,
        input logic [WORD_BITS-1:0] q
    );
        logic [WORD_BITS:0] sum;
        begin
            sum = {1'b0, x} + {1'b0, y};
            if (sum >= {1'b0, q})
                add_mod = sum - {1'b0, q};
            else
                add_mod = sum[WORD_BITS-1:0];
        end
    endfunction

    assign req_ready = !busy && !rsp_valid;

    always_comb begin
        product_next = product;
        if (multiplier[0])
            product_next = add_mod(product, multiplicand, modulus);
        multiplicand_next = add_mod(multiplicand, multiplicand, modulus);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy          <= 1'b0;
            count         <= '0;
            product       <= '0;
            multiplicand  <= '0;
            multiplier    <= '0;
            modulus       <= '0;
            rsp_valid     <= 1'b0;
            rsp_product   <= '0;
        end else begin
            if (rsp_valid && rsp_ready)
                rsp_valid <= 1'b0;

            if (req_valid && req_ready) begin
                busy         <= 1'b1;
                count        <= '0;
                product      <= '0;
                multiplicand <= req_a;
                multiplier   <= req_b;
                modulus      <= req_modulus;
            end else if (busy) begin
                product      <= product_next;
                multiplicand <= multiplicand_next;
                multiplier   <= multiplier >> 1;
                if (count == WORD_BITS - 1) begin
                    busy        <= 1'b0;
                    rsp_valid   <= 1'b1;
                    rsp_product <= product_next;
                end else begin
                    count <= count + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
