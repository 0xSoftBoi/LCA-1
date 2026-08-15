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

`ifdef FORMAL
    // Unbounded protocol invariants, proven by temporal induction with all
    // inputs unconstrained (see formal/prove.ys). The set is inductive:
    //
    //   I1  busy and rsp_valid are mutually exclusive;
    //   I2  req_ready is exactly the idle condition;
    //   I3  the iteration counter never exceeds WORD_BITS-1 while busy;
    //   I4  an unaccepted response holds valid with identical data across
    //       any cycle in which reset stays deasserted (reset legitimately
    //       cancels a pending response, so I4 is conditioned on it).
    //
    // This block is invisible to synthesis and simulation; only the formal
    // flow defines FORMAL.
    reg                 f_past_valid = 1'b0;
    reg                 f_past_rst_n = 1'b0;
    reg                 f_past_rsp_valid = 1'b0;
    reg                 f_past_rsp_ready = 1'b0;
    reg [WORD_BITS-1:0] f_past_rsp_product = '0;

    always @(posedge clk) begin
        f_past_valid       <= 1'b1;
        f_past_rst_n       <= rst_n;
        f_past_rsp_valid   <= rsp_valid;
        f_past_rsp_ready   <= rsp_ready;
        f_past_rsp_product <= rsp_product;
    end

    always @* begin
        assert(!(busy && rsp_valid));
        assert(req_ready == (!busy && !rsp_valid));
        if (busy)
            assert(count <= COUNT_BITS'(WORD_BITS - 1));
        if (f_past_valid && f_past_rst_n && rst_n &&
            f_past_rsp_valid && !f_past_rsp_ready) begin
            assert(rsp_valid);
            assert(rsp_product == f_past_rsp_product);
        end
    end
`endif

endmodule

`default_nettype wire
