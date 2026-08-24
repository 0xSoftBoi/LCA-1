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
// The transform schedule and twiddle constants match the pinned PQClean clean
// implementations. One butterfly is issued per clock. Coefficients are held in
// two fixed 128x32 banks. The bank function is XOR parity of the 8-bit logical
// coefficient address; every radix-2 butterfly pair differs in exactly one
// address bit, so both operands always land in opposite banks at every stage.
// Each bank therefore needs at most one read and one write per butterfly.
//
// Reset clears control state only. Coefficient memory is scrubbed by an
// explicit zeroize request over 256 cycles. A real SRAM macro cannot perform a
// synchronous 256-word clear in one clock. The sequential scrub and the fixed
// 1R/1W-per-bank topology are intentionally compatible with compiled SRAM
// wrappers instead of forcing an 8192-flop coefficient store.

module lca_ntt_accel (
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

    localparam [1:0] ST_IDLE      = 2'd0;
    localparam [1:0] ST_BUTTERFLY = 2'd1;
    localparam [1:0] ST_SCALE     = 2'd2;
    localparam [1:0] ST_ZEROIZE   = 2'd3;

    // Logical address A maps to:
    //   bank = ^A[7:0]
    //   row  = A[6:0]
    // This is a bijection because A[7] = bank ^ ^row. A butterfly peer is
    // A xor 2^k for the current radix-2 stage, which always flips bank parity.
    reg signed [31:0] coeff_bank0_q [0:127];
    reg signed [31:0] coeff_bank1_q [0:127];

    reg [1:0] state_q;
    reg [1:0] command_q;
    reg [7:0] len_q;
    reg [8:0] start_q;
    reg [8:0] j_q;
    reg [8:0] k_q;
    reg [7:0] scale_index_q;
    reg [7:0] zeroize_index_q;
    reg       zeroize_seen_q;
    reg signed [31:0] zeta_q;

    reg signed [31:0] a_value;
    reg signed [31:0] b_value;
    reg signed [31:0] difference_value;
    reg signed [31:0] product_value;
    reg signed [31:0] new_a;
    reg signed [31:0] new_b;
    reg signed [63:0] wide_product;
    reg [8:0] next_group_start;
    wire [8:0] butterfly_peer = j_q + {1'b0, len_q};
    wire       butterfly_j_bank = ^j_q[7:0];

`include "lca_ntt_zetas.svh"

    function automatic signed [31:0] coeff_read;
        input [7:0] address;
        begin
            if (^address)
                coeff_read = coeff_bank1_q[address[6:0]];
            else
                coeff_read = coeff_bank0_q[address[6:0]];
        end
    endfunction

    function automatic signed [31:0] mldsa_montgomery_reduce;
        input signed [63:0] value;
        reg signed [31:0] t;
        reg signed [63:0] adjusted;
        begin
            // Low-word multiplication implements the cast to int32_t in the
            // FIPS reference reduction (QINV = q^-1 mod 2^32).
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
            // v = round(2^26 / 3329) = 20159.
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

    assign coeff_rdata_o = coeff_read(coeff_addr_i);

    // Current butterfly arithmetic. ML-KEM assignments explicitly narrow to
    // 16 bits to reproduce the clean C implementation's int16_t semantics.
    // ML-DSA inverse subtraction is likewise materialized at signed 32-bit
    // width before multiplication, matching PQClean's int32_t expression and
    // preventing SystemVerilog context width from silently widening it to 64.
    always @* begin
        a_value = coeff_read(j_q[7:0]);
        b_value = coeff_read(butterfly_peer[7:0]);
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
            zeta_q           <= 32'sd0;
        end else begin
            // Edge-latch zeroization so a level held high by the top-level
            // scrub controller launches exactly one 256-cycle NTT scrub.
            if (!zeroize_i)
                zeroize_seen_q <= 1'b0;

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
                if (coeff_we_i && !busy_o && !zeroize_i) begin
                    if (^coeff_addr_i) begin
                        if (coeff_wstrb_i[0]) coeff_bank1_q[coeff_addr_i[6:0]][7:0]   <= coeff_wdata_i[7:0];
                        if (coeff_wstrb_i[1]) coeff_bank1_q[coeff_addr_i[6:0]][15:8]  <= coeff_wdata_i[15:8];
                        if (coeff_wstrb_i[2]) coeff_bank1_q[coeff_addr_i[6:0]][23:16] <= coeff_wdata_i[23:16];
                        if (coeff_wstrb_i[3]) coeff_bank1_q[coeff_addr_i[6:0]][31:24] <= coeff_wdata_i[31:24];
                    end else begin
                        if (coeff_wstrb_i[0]) coeff_bank0_q[coeff_addr_i[6:0]][7:0]   <= coeff_wdata_i[7:0];
                        if (coeff_wstrb_i[1]) coeff_bank0_q[coeff_addr_i[6:0]][15:8]  <= coeff_wdata_i[15:8];
                        if (coeff_wstrb_i[2]) coeff_bank0_q[coeff_addr_i[6:0]][23:16] <= coeff_wdata_i[23:16];
                        if (coeff_wstrb_i[3]) coeff_bank0_q[coeff_addr_i[6:0]][31:24] <= coeff_wdata_i[31:24];
                    end
                end

                case (state_q)
                    ST_IDLE: begin
                        if (start_i && !zeroize_i) begin
                            command_q <= command_i;
                            busy_o    <= 1'b1;
                            done_o    <= 1'b0;
                            start_q   <= 9'd0;
                            j_q       <= 9'd0;
                            state_q   <= ST_BUTTERFLY;
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
                                CMD_MLKEM_INTT: begin
                                    len_q  <= 8'd2;
                                    k_q    <= 9'd127;
                                    zeta_q <= sign_extend_16(mlkem_zeta(8'd127));
                                end
                            endcase
                        end
                    end

                    ST_BUTTERFLY: begin
                        // The parity-bank invariant makes these one write per
                        // bank, regardless of the transform stage.
                        if (butterfly_j_bank) begin
                            coeff_bank1_q[j_q[6:0]] <= new_a;
                            coeff_bank0_q[butterfly_peer[6:0]] <= new_b;
                        end else begin
                            coeff_bank0_q[j_q[6:0]] <= new_a;
                            coeff_bank1_q[butterfly_peer[6:0]] <= new_b;
                        end

                        if ((j_q + 1'b1) < (start_q + len_q)) begin
                            j_q <= j_q + 1'b1;
                        end else if (next_group_start < 9'd256) begin
                            start_q <= next_group_start;
                            j_q     <= next_group_start;
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
                                state_q       <= ST_SCALE;
                                scale_index_q <= 8'd0;
                            end else if (command_q == CMD_MLDSA_NTT || command_q == CMD_MLKEM_NTT) begin
                                len_q <= len_q >> 1;
                                k_q   <= k_q + 1'b1;
                                if (command_q == CMD_MLDSA_NTT)
                                    zeta_q <= mldsa_zeta(k_q[7:0] + 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] + 1'b1));
                            end else begin
                                len_q <= len_q << 1;
                                k_q   <= k_q - 1'b1;
                                if (command_q == CMD_MLDSA_INTT)
                                    zeta_q <= -mldsa_zeta(k_q[7:0] - 1'b1);
                                else
                                    zeta_q <= sign_extend_16(mlkem_zeta(k_q[7:0] - 1'b1));
                            end
                        end
                    end

                    ST_SCALE: begin
                        if (^scale_index_q) begin
                            if (command_q == CMD_MLDSA_INTT) begin
                                coeff_bank1_q[scale_index_q[6:0]] <= mldsa_montgomery_reduce(
                                    64'sd41978 * coeff_read(scale_index_q)
                                );
                            end else begin
                                coeff_bank1_q[scale_index_q[6:0]] <= sign_extend_16(
                                    mlkem_montgomery_reduce(32'sd1441 * $signed(coeff_read(scale_index_q)[15:0]))
                                );
                            end
                        end else begin
                            if (command_q == CMD_MLDSA_INTT) begin
                                coeff_bank0_q[scale_index_q[6:0]] <= mldsa_montgomery_reduce(
                                    64'sd41978 * coeff_read(scale_index_q)
                                );
                            end else begin
                                coeff_bank0_q[scale_index_q[6:0]] <= sign_extend_16(
                                    mlkem_montgomery_reduce(32'sd1441 * $signed(coeff_read(scale_index_q)[15:0]))
                                );
                            end
                        end

                        if (scale_index_q == 8'd255) begin
                            state_q <= ST_IDLE;
                            busy_o  <= 1'b0;
                            done_o  <= 1'b1;
                        end else begin
                            scale_index_q <= scale_index_q + 1'b1;
                        end
                    end

                    ST_ZEROIZE: begin
                        // One logical coefficient per cycle: exactly one bank
                        // write per cycle, portable to the SRAM macro boundary.
                        if (^zeroize_index_q)
                            coeff_bank1_q[zeroize_index_q[6:0]] <= 32'sd0;
                        else
                            coeff_bank0_q[zeroize_index_q[6:0]] <= 32'sd0;
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
