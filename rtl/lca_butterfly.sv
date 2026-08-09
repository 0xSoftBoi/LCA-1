`default_nettype none

module lca_butterfly #(
    parameter int WORD_BITS = 24
) (
    input  logic                 clk,
    input  logic                 rst_n,

    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic [1:0]           req_modulus_id,
    input  logic [WORD_BITS-1:0] req_a,
    input  logic [WORD_BITS-1:0] req_b,
    input  logic [WORD_BITS-1:0] req_twiddle,

    output logic                 rsp_valid,
    input  logic                 rsp_ready,
    output logic                 rsp_fault,
    output logic [WORD_BITS-1:0] rsp_a,
    output logic [WORD_BITS-1:0] rsp_b
);

    localparam logic [WORD_BITS-1:0] KEM_Q = 24'd3329;
    localparam logic [WORD_BITS-1:0] DSA_Q = 24'd8380417;

    logic [WORD_BITS-1:0] selected_modulus;
    logic                 request_valid;
    logic [WORD_BITS-1:0] a_saved;
    logic [WORD_BITS-1:0] modulus_saved;

    logic                 mul_req_valid;
    logic                 mul_req_ready;
    logic                 mul_rsp_valid;
    logic                 mul_rsp_ready;
    logic [WORD_BITS-1:0] mul_product;
    logic                 fault_pending;

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

    function automatic logic [WORD_BITS-1:0] sub_mod(
        input logic [WORD_BITS-1:0] x,
        input logic [WORD_BITS-1:0] y,
        input logic [WORD_BITS-1:0] q
    );
        logic [WORD_BITS:0] difference;
        begin
            if (x >= y)
                sub_mod = x - y;
            else begin
                difference = {1'b0, x} + {1'b0, q} - {1'b0, y};
                sub_mod = difference[WORD_BITS-1:0];
            end
        end
    endfunction

    always_comb begin
        case (req_modulus_id)
            2'd0: selected_modulus = KEM_Q;
            2'd1: selected_modulus = DSA_Q;
            default: selected_modulus = '0;
        endcase
        request_valid = (req_modulus_id <= 2'd1) &&
                        (req_a < selected_modulus) &&
                        (req_b < selected_modulus) &&
                        (req_twiddle < selected_modulus);
    end

    assign req_ready     = mul_req_ready && !fault_pending;
    assign mul_req_valid = req_valid && req_ready && request_valid;
    assign mul_rsp_ready = rsp_ready && !fault_pending;

    assign rsp_valid = fault_pending || mul_rsp_valid;
    assign rsp_fault = fault_pending;
    assign rsp_a = fault_pending ? '0 : add_mod(a_saved, mul_product, modulus_saved);
    assign rsp_b = fault_pending ? '0 : sub_mod(a_saved, mul_product, modulus_saved);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            a_saved      <= '0;
            modulus_saved <= '0;
            fault_pending <= 1'b0;
        end else begin
            if (fault_pending && rsp_ready)
                fault_pending <= 1'b0;

            if (req_valid && req_ready) begin
                if (request_valid) begin
                    a_saved       <= req_a;
                    modulus_saved <= selected_modulus;
                end else begin
                    fault_pending <= 1'b1;
                end
            end
        end
    end

    lca_modmul #(.WORD_BITS(WORD_BITS)) u_modmul (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_valid   (mul_req_valid),
        .req_ready   (mul_req_ready),
        .req_a       (req_b),
        .req_b       (req_twiddle),
        .req_modulus (selected_modulus),
        .rsp_valid   (mul_rsp_valid),
        .rsp_ready   (mul_rsp_ready),
        .rsp_product (mul_product)
    );

endmodule

`default_nettype wire
