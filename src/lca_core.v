// SPDX-License-Identifier: Apache-2.0
`default_nettype none

// LCA-1 bridge lattice arithmetic core.
//
// op = 2'b00: out0 = a*b mod q
// op = 2'b01: Cooley-Tukey: t=zeta*b; out0=a+t; out1=a-t
// op = 2'b10: Gentleman-Sande: out0=a+b; out1=zeta*(a-b)
// mode_kem = 0 selects FIPS-204 q=8380417 (ML-DSA)
// mode_kem = 1 selects FIPS-203 q=3329    (ML-KEM)
module lca_core (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        mode_kem,
    input  wire [1:0]  op,
    input  wire [23:0] a,
    input  wire [23:0] b,
    input  wire [23:0] zeta,
    output reg  [23:0] out0,
    output reg  [23:0] out1,
    output reg         busy,
    output reg         done,
    output reg         error
);

    localparam [23:0] Q_MLDSA = 24'd8380417;
    localparam [23:0] Q_MLKEM = 24'd3329;

    localparam [1:0] OP_MUL = 2'b00;
    localparam [1:0] OP_CT  = 2'b01;
    localparam [1:0] OP_GS  = 2'b10;

    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_LAUNCH = 2'd1;
    localparam [1:0] ST_WAIT   = 2'd2;

    reg [1:0] state;
    reg [1:0] op_latched;
    reg [23:0] q_latched;
    reg [23:0] a_latched;
    reg [23:0] b_latched;
    reg [23:0] zeta_latched;
    reg [23:0] gs_sum_latched;

    reg         mul_start;
    reg  [23:0] mul_a;
    reg  [23:0] mul_b;
    wire [23:0] mul_result;
    wire        mul_busy;
    wire        mul_done;
    wire        mul_error;

    function [23:0] add_mod;
        input [23:0] x;
        input [23:0] y;
        input [23:0] q;
        reg   [24:0] sum;
        begin
            sum = {1'b0, x} + {1'b0, y};
            if (sum >= {1'b0, q})
                add_mod = sum - {1'b0, q};
            else
                add_mod = sum[23:0];
        end
    endfunction

    function [23:0] sub_mod;
        input [23:0] x;
        input [23:0] y;
        input [23:0] q;
        begin
            if (x >= y)
                sub_mod = x - y;
            else
                sub_mod = q - (y - x);
        end
    endfunction

    lca_modmul #(.WIDTH(24)) u_modmul (
        .clk(clk),
        .rst_n(rst_n),
        .start(mul_start),
        .a(mul_a),
        .b(mul_b),
        .modulus(q_latched),
        .result(mul_result),
        .busy(mul_busy),
        .done(mul_done),
        .error(mul_error)
    );

    wire [23:0] selected_q = mode_kem ? Q_MLKEM : Q_MLDSA;
    wire inputs_canonical = (a < selected_q) && (b < selected_q) &&
                            ((op == OP_MUL) || (zeta < selected_q));
    wire opcode_valid = (op == OP_MUL) || (op == OP_CT) || (op == OP_GS);

    // Keep the otherwise-internal multiplier busy signal visible to synthesis
    // checks without making it part of the external interface.
    wire _unused_mul_busy = mul_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            op_latched     <= OP_MUL;
            q_latched      <= Q_MLDSA;
            a_latched      <= 24'd0;
            b_latched      <= 24'd0;
            zeta_latched   <= 24'd0;
            gs_sum_latched <= 24'd0;
            mul_start      <= 1'b0;
            mul_a          <= 24'd0;
            mul_b          <= 24'd0;
            out0           <= 24'd0;
            out1           <= 24'd0;
            busy           <= 1'b0;
            done           <= 1'b0;
            error          <= 1'b0;
        end else begin
            done      <= 1'b0;
            mul_start <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (!opcode_valid || !inputs_canonical) begin
                            out0  <= 24'd0;
                            out1  <= 24'd0;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            error <= 1'b1;
                        end else begin
                            op_latched   <= op;
                            q_latched    <= selected_q;
                            a_latched    <= a;
                            b_latched    <= b;
                            zeta_latched <= zeta;
                            busy         <= 1'b1;
                            error        <= 1'b0;
                            state        <= ST_LAUNCH;
                        end
                    end
                end

                ST_LAUNCH: begin
                    case (op_latched)
                        OP_MUL: begin
                            mul_a <= a_latched;
                            mul_b <= b_latched;
                        end
                        OP_CT: begin
                            mul_a <= b_latched;
                            mul_b <= zeta_latched;
                        end
                        OP_GS: begin
                            mul_a          <= sub_mod(a_latched, b_latched, q_latched);
                            mul_b          <= zeta_latched;
                            gs_sum_latched <= add_mod(a_latched, b_latched, q_latched);
                        end
                        default: begin
                            mul_a <= 24'd0;
                            mul_b <= 24'd0;
                        end
                    endcase
                    mul_start <= 1'b1;
                    state     <= ST_WAIT;
                end

                ST_WAIT: begin
                    if (mul_done) begin
                        if (mul_error) begin
                            out0  <= 24'd0;
                            out1  <= 24'd0;
                            error <= 1'b1;
                        end else begin
                            case (op_latched)
                                OP_MUL: begin
                                    out0 <= mul_result;
                                    out1 <= 24'd0;
                                end
                                OP_CT: begin
                                    out0 <= add_mod(a_latched, mul_result, q_latched);
                                    out1 <= sub_mod(a_latched, mul_result, q_latched);
                                end
                                OP_GS: begin
                                    out0 <= gs_sum_latched;
                                    out1 <= mul_result;
                                end
                                default: begin
                                    out0  <= 24'd0;
                                    out1  <= 24'd0;
                                    error <= 1'b1;
                                end
                            endcase
                        end
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state <= ST_IDLE;
                    busy  <= 1'b0;
                    error <= 1'b1;
                end
            endcase
        end
    end

endmodule

`default_nettype wire

