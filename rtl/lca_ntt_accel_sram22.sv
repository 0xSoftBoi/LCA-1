// SPDX-License-Identifier: Apache-2.0
//
// SRAM22-backed Rev-A NTT/INTT candidate.
//
// This module implements the same arithmetic/schedule as lca_ntt_accel but
// honors the selected SRAM22 macro's synchronous single-port semantics. Each
// radix-2 butterfly uses two clocks:
//   1. read the two parity banks in parallel;
//   2. compute and write the two results in parallel.
//
// Logical coefficient address A maps to bank=parity(A[7:0]), row=A[6:0]. A
// radix-2 pair differs in one address bit, so its operands always occupy
// opposite banks. This guarantees one access per physical bank in both phases.

`default_nettype none

module lca_ntt_accel_sram22 (
`ifdef USE_POWER_PINS
    inout wire         vdd,
    inout wire         vss,
`endif
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         zeroize_i,
    input  wire         start_i,
    input  wire [1:0]   command_i,
    output reg          busy_o,
    output reg          done_o,
    input  wire         coeff_we_i,
    input  wire [7:0]   coeff_addr_i,
    input  wire [31:0]  coeff_wdata_i,
    input  wire [3:0]   coeff_wstrb_i,
    output wire [31:0]  coeff_rdata_o
);
    localparam [1:0] CMD_MLDSA_NTT  = 2'd0;
    localparam [1:0] CMD_MLDSA_INTT = 2'd1;
    localparam [1:0] CMD_MLKEM_NTT  = 2'd2;
    localparam [1:0] CMD_MLKEM_INTT = 2'd3;

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_BF_READ     = 3'd1;
    localparam [2:0] ST_BF_WRITE    = 3'd2;
    localparam [2:0] ST_SCALE_READ  = 3'd3;
    localparam [2:0] ST_SCALE_WRITE = 3'd4;
    localparam [2:0] ST_ZEROIZE     = 3'd5;

    reg [2:0] state_q;
    reg [1:0] command_q;
    reg [7:0] len_q;
    reg [8:0] start_q;
    reg [8:0] j_q;
    reg [8:0] k_q;
    reg [7:0] scale_index_q;
    reg [6:0] zeroize_row_q;
    reg       zeroize_seen_q;
    reg       bf_j_bank_q;
    reg       scale_bank_q;
    reg       host_read_bank_q;
    reg signed [31:0] zeta_q;

    wire [8:0] butterfly_peer = j_q + {1'b0, len_q};
    wire       j_bank = ^j_q[7:0];
    wire       peer_bank = ^butterfly_peer[7:0];
    wire [6:0] j_row = j_q[6:0];
    wire [6:0] peer_row = butterfly_peer[6:0];
    wire       host_bank = ^coeff_addr_i;
    wire [6:0] host_row = coeff_addr_i[6:0];

`include "lca_ntt_zetas.svh"

    function automatic signed [31:0] mldsa_montgomery_reduce;
        input signed [63:0] value;
        reg signed [31:0] t;
        reg signed [63:0] adjusted;
        begin
            t = value[31:0] * 32'd58728449;
            adjusted = value - (t * 64'sd8380417);
            mldsa_montgomery_reduce = adjusted >>> 32;
        end
    endfunction

    function automatic signed [15:0] mlkem_montgomery_reduce;
        input signed [31:0] value;
        reg signed [15:0] t;
        reg signed [31:0] adjusted;
        begin
            t = $signed(value[15:0]) * -16'sd3327;
            adjusted = value - (t * 32'sd3329);
            mlkem_montgomery_reduce = adjusted >>> 16;
        end
    endfunction

    function automatic signed [15:0] mlkem_barrett_reduce;
        input signed [15:0] value;
        reg signed [31:0] t;
        begin
            t = ((32'sd20159 * value) + 32'sd33554432) >>> 26;
            mlkem_barrett_reduce = value - (t * 32'sd3329);
        end
    endfunction

    function automatic signed [31:0] sign_extend_16;
        input signed [15:0] value;
        begin
            sign_extend_16 = {{16{value[15]}}, value};
        end
    endfunction

    reg bank0_ce, bank0_we;
    reg [3:0] bank0_wmask;
    reg [6:0] bank0_addr;
    reg [31:0] bank0_wdata;
    wire [31:0] bank0_rdata;
    reg bank1_ce, bank1_we;
    reg [3:0] bank1_wmask;
    reg [6:0] bank1_addr;
    reg [31:0] bank1_wdata;
    wire [31:0] bank1_rdata;

    reg signed [31:0] a_value;
    reg signed [31:0] b_value;
    reg signed [31:0] difference_value;
    reg signed [31:0] product_value;
    reg signed [31:0] new_a;
    reg signed [31:0] new_b;
    reg signed [63:0] wide_product;
    reg signed [31:0] scale_value;
    reg signed [31:0] scaled_value;
    reg [8:0] next_group_start;

    // Registered host reads: address the selected bank while idle, remember
    // which bank was selected at the read clock, and mux its registered dout.
    assign coeff_rdata_o = host_read_bank_q ? bank1_rdata : bank0_rdata;

    always @* begin
        if (bf_j_bank_q) begin
            a_value = $signed(bank1_rdata);
            b_value = $signed(bank0_rdata);
        end else begin
            a_value = $signed(bank0_rdata);
            b_value = $signed(bank1_rdata);
        end
        difference_value = a_value - b_value;
        product_value = 32'sd0;
        new_a = a_value;
        new_b = b_value;
        wide_product = 64'sd0;

        case (command_q)
            CMD_MLDSA_NTT: begin
                wide_product = $signed(zeta_q) * $signed(b_value);
                product_value = mldsa_montgomery_reduce(wide_product);
                new_a = a_value + product_value;
                new_b = a_value - product_value;
            end
            CMD_MLDSA_INTT: begin
                new_a = a_value + b_value;
                wide_product = $signed(zeta_q) * $signed(difference_value);
                new_b = mldsa_montgomery_reduce(wide_product);
            end
            CMD_MLKEM_NTT: begin
                product_value = sign_extend_16(
                    mlkem_montgomery_reduce($signed(zeta_q[15:0]) * $signed(b_value[15:0]))
                );
                new_a = sign_extend_16($signed(a_value[15:0]) + $signed(product_value[15:0]));
                new_b = sign_extend_16($signed(a_value[15:0]) - $signed(product_value[15:0]));
            end
            CMD_MLKEM_INTT: begin
                new_a = sign_extend_16(
                    mlkem_barrett_reduce($signed(a_value[15:0]) + $signed(b_value[15:0]))
                );
                product_value = sign_extend_16($signed(b_value[15:0]) - $signed(a_value[15:0]));
                new_b = sign_extend_16(
                    mlkem_montgomery_reduce($signed(zeta_q[15:0]) * $signed(product_value[15:0]))
                );
            end
            default: begin end
        endcase

        scale_value = scale_bank_q ? $signed(bank1_rdata) : $signed(bank0_rdata);
        if (command_q == CMD_MLDSA_INTT)
            scaled_value = mldsa_montgomery_reduce(64'sd41978 * scale_value);
        else
            scaled_value = sign_extend_16(
                mlkem_montgomery_reduce(32'sd1441 * $signed(scale_value[15:0]))
            );
        next_group_start = start_q + ({1'b0, len_q} << 1);
    end

    // Drive the two single-port macros according to the phase. No bank is ever
    // asked to read and write on the same clock.
    always @* begin
        bank0_ce = 1'b0; bank0_we = 1'b0; bank0_wmask = 4'd0;
        bank0_addr = 7'd0; bank0_wdata = 32'd0;
        bank1_ce = 1'b0; bank1_we = 1'b0; bank1_wmask = 4'd0;
        bank1_addr = 7'd0; bank1_wdata = 32'd0;

        case (state_q)
            ST_IDLE: begin
                if (coeff_we_i) begin
                    if (host_bank) begin
                        bank1_ce = 1'b1; bank1_we = 1'b1; bank1_wmask = coeff_wstrb_i;
                        bank1_addr = host_row; bank1_wdata = coeff_wdata_i;
                    end else begin
                        bank0_ce = 1'b1; bank0_we = 1'b1; bank0_wmask = coeff_wstrb_i;
                        bank0_addr = host_row; bank0_wdata = coeff_wdata_i;
                    end
                end else begin
                    if (host_bank) begin
                        bank1_ce = 1'b1; bank1_addr = host_row;
                    end else begin
                        bank0_ce = 1'b1; bank0_addr = host_row;
                    end
                end
            end
            ST_BF_READ: begin
                bank0_ce = 1'b1; bank1_ce = 1'b1;
                if (!j_bank) begin
                    bank0_addr = j_row; bank1_addr = peer_row;
                end else begin
                    bank1_addr = j_row; bank0_addr = peer_row;
                end
            end
            ST_BF_WRITE: begin
                bank0_ce = 1'b1; bank0_we = 1'b1; bank0_wmask = 4'hf;
                bank1_ce = 1'b1; bank1_we = 1'b1; bank1_wmask = 4'hf;
                if (!bf_j_bank_q) begin
                    bank0_addr = j_row; bank0_wdata = new_a;
                    bank1_addr = peer_row; bank1_wdata = new_b;
                end else begin
                    bank1_addr = j_row; bank1_wdata = new_a;
                    bank0_addr = peer_row; bank0_wdata = new_b;
                end
            end
            ST_SCALE_READ: begin
                if (^scale_index_q) begin
                    bank1_ce = 1'b1; bank1_addr = scale_index_q[6:0];
                end else begin
                    bank0_ce = 1'b1; bank0_addr = scale_index_q[6:0];
                end
            end
            ST_SCALE_WRITE: begin
                if (scale_bank_q) begin
                    bank1_ce = 1'b1; bank1_we = 1'b1; bank1_wmask = 4'hf;
                    bank1_addr = scale_index_q[6:0]; bank1_wdata = scaled_value;
                end else begin
                    bank0_ce = 1'b1; bank0_we = 1'b1; bank0_wmask = 4'hf;
                    bank0_addr = scale_index_q[6:0]; bank0_wdata = scaled_value;
                end
            end
            ST_ZEROIZE: begin
                bank0_ce = 1'b1; bank0_we = 1'b1; bank0_wmask = 4'hf;
                bank0_addr = zeroize_row_q; bank0_wdata = 32'd0;
                bank1_ce = 1'b1; bank1_we = 1'b1; bank1_wmask = 4'hf;
                bank1_addr = zeroize_row_q; bank1_wdata = 32'd0;
            end
            default: begin end
        endcase
    end

    lca_sram22_128x32 u_bank0 (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk_i(clk_i), .rst_ni(rst_ni), .ce_i(bank0_ce), .we_i(bank0_we),
        .wmask_i(bank0_wmask), .addr_i(bank0_addr), .wdata_i(bank0_wdata),
        .rdata_o(bank0_rdata)
    );
    lca_sram22_128x32 u_bank1 (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk_i(clk_i), .rst_ni(rst_ni), .ce_i(bank1_ce), .we_i(bank1_we),
        .wmask_i(bank1_wmask), .addr_i(bank1_addr), .wdata_i(bank1_wdata),
        .rdata_o(bank1_rdata)
    );

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= ST_IDLE;
            command_q <= CMD_MLDSA_NTT;
            busy_o <= 1'b0;
            done_o <= 1'b0;
            len_q <= 8'd0;
            start_q <= 9'd0;
            j_q <= 9'd0;
            k_q <= 9'd0;
            scale_index_q <= 8'd0;
            zeroize_row_q <= 7'd0;
            zeroize_seen_q <= 1'b0;
            bf_j_bank_q <= 1'b0;
            scale_bank_q <= 1'b0;
            host_read_bank_q <= 1'b0;
            zeta_q <= 32'sd0;
        end else begin
            if (!zeroize_i)
                zeroize_seen_q <= 1'b0;

            if (state_q == ST_IDLE && !coeff_we_i)
                host_read_bank_q <= host_bank;

            if (zeroize_i && !zeroize_seen_q) begin
                zeroize_seen_q <= 1'b1;
                state_q <= ST_ZEROIZE;
                busy_o <= 1'b1;
                done_o <= 1'b0;
                zeroize_row_q <= 7'd0;
                len_q <= 8'd0;
                start_q <= 9'd0;
                j_q <= 9'd0;
                k_q <= 9'd0;
                scale_index_q <= 8'd0;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i && !zeroize_i) begin
                            command_q <= command_i;
                            busy_o <= 1'b1;
                            done_o <= 1'b0;
                            start_q <= 9'd0;
                            j_q <= 9'd0;
                            state_q <= ST_BF_READ;
                            case (command_i)
                                CMD_MLDSA_NTT: begin len_q <= 8'd128; k_q <= 9'd1; zeta_q <= mldsa_zeta(8'd1); end
                                CMD_MLDSA_INTT: begin len_q <= 8'd1; k_q <= 9'd255; zeta_q <= -mldsa_zeta(8'd255); end
                                CMD_MLKEM_NTT: begin len_q <= 8'd128; k_q <= 9'd1; zeta_q <= sign_extend_16(mlkem_zeta(8'd1)); end
                                default: begin len_q <= 8'd2; k_q <= 9'd127; zeta_q <= sign_extend_16(mlkem_zeta(8'd127)); end
                            endcase
                        end
                    end

                    ST_BF_READ: begin
                        bf_j_bank_q <= j_bank;
                        state_q <= ST_BF_WRITE;
                    end

                    ST_BF_WRITE: begin
                        if ((j_q + 1'b1) < (start_q + len_q)) begin
                            j_q <= j_q + 1'b1;
                            state_q <= ST_BF_READ;
                        end else if (next_group_start < 9'd256) begin
                            start_q <= next_group_start;
                            j_q <= next_group_start;
                            if (command_q == CMD_MLDSA_NTT || command_q == CMD_MLKEM_NTT) begin
                                k_q <= k_q + 1'b1;
                                if (command_q == CMD_MLDSA_NTT)
                                    zeta_q <= mldsa_zeta(k_q[7:0] + 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] + 1'b1));
                            end else begin
                                k_q <= k_q - 1'b1;
                                if (command_q == CMD_MLDSA_INTT)
                                    zeta_q <= -mldsa_zeta(k_q[7:0] - 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] - 1'b1));
                            end
                            state_q <= ST_BF_READ;
                        end else begin
                            start_q <= 9'd0;
                            j_q <= 9'd0;
                            if ((command_q == CMD_MLDSA_NTT && len_q == 8'd1) ||
                                (command_q == CMD_MLKEM_NTT && len_q == 8'd2)) begin
                                state_q <= ST_IDLE;
                                busy_o <= 1'b0;
                                done_o <= 1'b1;
                            end else if ((command_q == CMD_MLDSA_INTT && len_q == 8'd128) ||
                                         (command_q == CMD_MLKEM_INTT && len_q == 8'd128)) begin
                                scale_index_q <= 8'd0;
                                state_q <= ST_SCALE_READ;
                            end else if (command_q == CMD_MLDSA_NTT || command_q == CMD_MLKEM_NTT) begin
                                len_q <= len_q >> 1;
                                k_q <= k_q + 1'b1;
                                if (command_q == CMD_MLDSA_NTT)
                                    zeta_q <= mldsa_zeta(k_q[7:0] + 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] + 1'b1));
                                state_q <= ST_BF_READ;
                            end else begin
                                len_q <= len_q << 1;
                                k_q <= k_q - 1'b1;
                                if (command_q == CMD_MLDSA_INTT)
                                    zeta_q <= -mldsa_zeta(k_q[7:0] - 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] - 1'b1));
                                state_q <= ST_BF_READ;
                            end
                        end
                    end

                    ST_SCALE_READ: begin
                        scale_bank_q <= ^scale_index_q;
                        state_q <= ST_SCALE_WRITE;
                    end

                    ST_SCALE_WRITE: begin
                        if (scale_index_q == 8'd255) begin
                            state_q <= ST_IDLE;
                            busy_o <= 1'b0;
                            done_o <= 1'b1;
                        end else begin
                            scale_index_q <= scale_index_q + 1'b1;
                            state_q <= ST_SCALE_READ;
                        end
                    end

                    ST_ZEROIZE: begin
                        if (zeroize_row_q == 7'd127) begin
                            zeroize_row_q <= 7'd0;
                            state_q <= ST_IDLE;
                            busy_o <= 1'b0;
                        end else begin
                            zeroize_row_q <= zeroize_row_q + 1'b1;
                        end
                    end

                    default: begin
                        state_q <= ST_IDLE;
                        busy_o <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule

`default_nettype wire
