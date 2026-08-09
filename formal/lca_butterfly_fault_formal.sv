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
        .req_modulus_id(2'd0),
        .req_a(24'd3329),
        .req_b(24'd0),
        .req_twiddle(24'd0),
        .rsp_valid,
        .rsp_ready,
        .rsp_fault,
        .rsp_a,
        .rsp_b
    );
endmodule

`default_nettype wire
