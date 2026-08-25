// SPDX-License-Identifier: Apache-2.0
//
// Shared 256-coefficient NTT/INTT engine for the LTP Level-3 profile.
//
// command_i:
//   0 = ML-DSA-65 forward NTT
//   1 = ML-DSA-65 inverse NTT to Montgomery domain
//   2 = ML-KEM-768 forward NTT
//   3 = ML-KEM-768 inverse NTT to Montgomery domain
//
// Rev-A uses two 128x32 single-port SRAM banks. Logical coefficient address A
// maps to bank=parity(A) and row=A[6:0]. Every radix-2 butterfly pair differs
// in exactly one address bit, therefore the operands always occupy opposite
// banks. The controller performs an explicit READ phase followed by an
// EXEC/WRITE phase; each bank performs one legal 1RW macro operation per clock.
//
// The transform schedule and twiddle constants match the pinned PQClean clean
// implementations. Reset clears control state only; explicit zeroization
// scrubs one logical coefficient per clock over 256 clocks.

module lca_ntt_accel (
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         zeroize_i,

    input  wire         start_i,
    input  wire [1:0]   command_i,
    output reg          busy_o,
    output reg          done_o,

    // Host coefficient window. Writes commit on the rising edge. Reads are
    // synchronous: coeff_rdata_o reflects the address presented on the most
    // recent idle read cycle.
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
    reg [7:0] zeroize_index_q;
    reg       zeroize_seen_q;
    reg       host_read_bank_q;
    reg signed [31:0] zeta_q;

    reg signed [31:0] a_value;
    reg signed [31:0] b_value;
    reg signed [31:0] difference_value;
    reg signed [31:0] product_value;
    reg signed [31:0] new_a;
    reg signed [31:0] new_b;
    reg signed [31:0] scale_result;
    reg signed [63:0] wide_product;
    reg [8:0] next_group_start;

    wire [8:0] butterfly_peer = j_q + {1'b0, len_q};
    wire       butterfly_j_bank = ^j_q[7:0];
    wire       scale_bank = ^scale_index_q;
    wire       zeroize_bank = ^zeroize_index_q;

    reg        bank0_ce;
    reg        bank0_we;
    reg [3:0]  bank0_wmask;
    reg [6:0]  bank0_addr;
    reg [31:0] bank0_wdata;
    wire [31:0] bank0_rdata;

    reg        bank1_ce;
    reg        bank1_we;
    reg [3:0]  bank1_wmask;
    reg [6:0]  bank1_addr;
    reg [31:0] bank1_wdata;
    wire [31:0] bank1_rdata;

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

    lca_sram_1rw #(.WORDS(128), .ADDR_W(7)) u_coeff_bank0 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(bank0_ce), .we_i(bank0_we), .wmask_i(bank0_wmask),
        .addr_i(bank0_addr), .wdata_i(bank0_wdata), .rdata_o(bank0_rdata)
    );

    lca_sram_1rw #(.WORDS(128), .ADDR_W(7)) u_coeff_bank1 (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .ce_i(bank1_ce), .we_i(bank1_we), .wmask_i(bank1_wmask),
        .addr_i(bank1_addr), .wdata_i(bank1_wdata), .rdata_o(bank1_rdata)
    );

    assign coeff_rdata_o = host_read_bank_q ? bank1_rdata : bank0_rdata;

    wire signed [31:0] scale_word = scale_bank ? $signed(bank1_rdata) : $signed(bank0_rdata);
    wire signed [15:0] scale_word16 = scale_word[15:0];

    // Read data from the two SRAM banks becomes valid during ST_BF_WRITE.
    // Reorder it back into logical (j, j+len) operand order.
    always @* begin
        if (butterfly_j_bank) begin
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
            default: begin
                new_a = a_value;
                new_b = b_value;
            end
        endcase

        next_group_start = start_q + ({1'b0, len_q} << 1);
    end

    // Inverse final scaling consumes the registered output of ST_SCALE_READ.
    always @* begin
        if (command_q == CMD_MLDSA_INTT) begin
            scale_result = mldsa_montgomery_reduce(64'sd41978 * scale_word);
        end else begin
            scale_result = sign_extend_16(
                mlkem_montgomery_reduce(32'sd1441 * scale_word16)
            );
        end
    end

    // SRAM port scheduler. This is the architectural macro contract: no bank
    // is ever asked to read and write in the same clock.
    always @* begin
        bank0_ce = 1'b0;
        bank0_we = 1'b0;
        bank0_wmask = 4'b0000;
        bank0_addr = 7'd0;
        bank0_wdata = 32'd0;
        bank1_ce = 1'b0;
        bank1_we = 1'b0;
        bank1_wmask = 4'b0000;
        bank1_addr = 7'd0;
        bank1_wdata = 32'd0;

        case (state_q)
            ST_IDLE: begin
                if (!start_i && !zeroize_i) begin
                    if (^coeff_addr_i) begin
                        bank1_ce = 1'b1;
                        bank1_we = coeff_we_i;
                        bank1_wmask = coeff_we_i ? coeff_wstrb_i : 4'b0000;
                        bank1_addr = coeff_addr_i[6:0];
                        bank1_wdata = coeff_wdata_i;
                    end else begin
                        bank0_ce = 1'b1;
                        bank0_we = coeff_we_i;
                        bank0_wmask = coeff_we_i ? coeff_wstrb_i : 4'b0000;
                        bank0_addr = coeff_addr_i[6:0];
                        bank0_wdata = coeff_wdata_i;
                    end
                end
            end

            ST_BF_READ: begin
                bank0_ce = 1'b1;
                bank1_ce = 1'b1;
                if (butterfly_j_bank) begin
                    bank1_addr = j_q[6:0];
                    bank0_addr = butterfly_peer[6:0];
                end else begin
                    bank0_addr = j_q[6:0];
                    bank1_addr = butterfly_peer[6:0];
                end
            end

            ST_BF_WRITE: begin
                bank0_ce = 1'b1;
                bank0_we = 1'b1;
                bank0_wmask = 4'b1111;
                bank1_ce = 1'b1;
                bank1_we = 1'b1;
                bank1_wmask = 4'b1111;
                if (butterfly_j_bank) begin
                    bank1_addr = j_q[6:0];
                    bank1_wdata = new_a;
                    bank0_addr = butterfly_peer[6:0];
                    bank0_wdata = new_b;
                end else begin
                    bank0_addr = j_q[6:0];
                    bank0_wdata = new_a;
                    bank1_addr = butterfly_peer[6:0];
                    bank1_wdata = new_b;
                end
            end

            ST_SCALE_READ: begin
                if (scale_bank) begin
                    bank1_ce = 1'b1;
                    bank1_addr = scale_index_q[6:0];
                end else begin
                    bank0_ce = 1'b1;
                    bank0_addr = scale_index_q[6:0];
                end
            end

            ST_SCALE_WRITE: begin
                if (scale_bank) begin
                    bank1_ce = 1'b1;
                    bank1_we = 1'b1;
                    bank1_wmask = 4'b1111;
                    bank1_addr = scale_index_q[6:0];
                    bank1_wdata = scale_result;
                end else begin
                    bank0_ce = 1'b1;
                    bank0_we = 1'b1;
                    bank0_wmask = 4'b1111;
                    bank0_addr = scale_index_q[6:0];
                    bank0_wdata = scale_result;
                end
            end

            ST_ZEROIZE: begin
                if (zeroize_bank) begin
                    bank1_ce = 1'b1;
                    bank1_we = 1'b1;
                    bank1_wmask = 4'b1111;
                    bank1_addr = zeroize_index_q[6:0];
                    bank1_wdata = 32'd0;
                end else begin
                    bank0_ce = 1'b1;
                    bank0_we = 1'b1;
                    bank0_wmask = 4'b1111;
                    bank0_addr = zeroize_index_q[6:0];
                    bank0_wdata = 32'd0;
                end
            end

            default: begin end
        endcase
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q          <= ST_IDLE;
            command_q        <= CMD_MLDSA_NTT;
            busy_o           <= 1'b0;
            done_o           <= 1'b0;
            len_q            <= 8'd0;
            start_q          <= 9'd0;
            j_q              <= 9'd0;
            k_q              <= 9'd0;
            scale_index_q    <= 8'd0;
            zeroize_index_q  <= 8'd0;
            zeroize_seen_q   <= 1'b0;
            host_read_bank_q <= 1'b0;
            zeta_q           <= 32'sd0;
        end else begin
            if (!zeroize_i)
                zeroize_seen_q <= 1'b0;

            if (state_q == ST_IDLE && !start_i && !zeroize_i && !coeff_we_i)
                host_read_bank_q <= ^coeff_addr_i;

            if (zeroize_i && !zeroize_seen_q) begin
                zeroize_seen_q  <= 1'b1;
                state_q         <= ST_ZEROIZE;
                busy_o          <= 1'b1;
                done_o          <= 1'b0;
                len_q           <= 8'd0;
                start_q         <= 9'd0;
                j_q             <= 9'd0;
                k_q             <= 9'd0;
                scale_index_q   <= 8'd0;
                zeroize_index_q <= 8'd0;
                zeta_q          <= 32'sd0;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (start_i && !zeroize_i) begin
                            command_q <= command_i;
                            busy_o    <= 1'b1;
                            done_o    <= 1'b0;
                            start_q   <= 9'd0;
                            j_q       <= 9'd0;
                            state_q   <= ST_BF_READ;
                            case (command_i)
                                CMD_MLDSA_NTT: begin
                                    len_q  <= 8'd128;
                                    k_q    <= 9'd1;
                                    zeta_q <= mldsa_zeta(8'd1);
                                end
                                CMD_MLDSA_INTT: begin
                                    len_q  <= 8'd1;
                                    k_q    <= 9'd255;
                                    zeta_q <= -mldsa_zeta(8'd255);
                                end
                                CMD_MLKEM_NTT: begin
                                    len_q  <= 8'd128;
                                    k_q    <= 9'd1;
                                    zeta_q <= sign_extend_16(mlkem_zeta(8'd1));
                                end
                                default: begin
                                    len_q  <= 8'd2;
                                    k_q    <= 9'd127;
                                    zeta_q <= sign_extend_16(mlkem_zeta(8'd127));
                                end
                            endcase
                        end
                    end

                    ST_BF_READ: begin
                        // SRAM outputs update on this edge and are consumed in
                        // the following EXEC/WRITE cycle.
                        state_q <= ST_BF_WRITE;
                    end

                    ST_BF_WRITE: begin
                        if ((j_q + 1'b1) < (start_q + len_q)) begin
                            j_q <= j_q + 1'b1;
                            state_q <= ST_BF_READ;
                        end else if (next_group_start < 9'd256) begin
                            start_q <= next_group_start;
                            j_q     <= next_group_start;
                            state_q <= ST_BF_READ;
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
                        end else begin
                            start_q <= 9'd0;
                            j_q     <= 9'd0;
                            if ((command_q == CMD_MLDSA_NTT && len_q == 8'd1) ||
                                (command_q == CMD_MLKEM_NTT && len_q == 8'd2)) begin
                                state_q <= ST_IDLE;
                                busy_o  <= 1'b0;
                                done_o  <= 1'b1;
                            end else if ((command_q == CMD_MLDSA_INTT && len_q == 8'd128) ||
                                         (command_q == CMD_MLKEM_INTT && len_q == 8'd128)) begin
                                state_q       <= ST_SCALE_READ;
                                scale_index_q <= 8'd0;
                            end else if (command_q == CMD_MLDSA_NTT || command_q == CMD_MLKEM_NTT) begin
                                len_q <= len_q >> 1;
                                k_q   <= k_q + 1'b1;
                                state_q <= ST_BF_READ;
                                if (command_q == CMD_MLDSA_NTT)
                                    zeta_q <= mldsa_zeta(k_q[7:0] + 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] + 1'b1));
                            end else begin
                                len_q <= len_q << 1;
                                k_q   <= k_q - 1'b1;
                                state_q <= ST_BF_READ;
                                if (command_q == CMD_MLDSA_INTT)
                                    zeta_q <= -mldsa_zeta(k_q[7:0] - 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] - 1'b1));
                            end
                        end
                    end

                    ST_SCALE_READ: begin
                        state_q <= ST_SCALE_WRITE;
                    end

                    ST_SCALE_WRITE: begin
                        if (scale_index_q == 8'd255) begin
                            state_q <= ST_IDLE;
                            busy_o  <= 1'b0;
                            done_o  <= 1'b1;
                        end else begin
                            scale_index_q <= scale_index_q + 1'b1;
                            state_q <= ST_SCALE_READ;
                        end
                    end

                    ST_ZEROIZE: begin
                        done_o <= 1'b0;
                        if (zeroize_index_q == 8'd255) begin
                            zeroize_index_q <= 8'd0;
                            state_q         <= ST_IDLE;
                            busy_o          <= 1'b0;
                        end else begin
                            zeroize_index_q <= zeroize_index_q + 1'b1;
                            busy_o          <= 1'b1;
                        end
                    end

                    default: begin
                        state_q <= ST_IDLE;
                        busy_o  <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
