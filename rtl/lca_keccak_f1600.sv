// SPDX-License-Identifier: Apache-2.0
//
// Iterative Keccak-f[1600] permutation engine.
//
// One full round is evaluated per clock. Software loads and reads the 25
// little-endian 64-bit lanes through a 32-bit window. SHA3/SHAKE padding and
// absorb/squeeze bookkeeping remain in firmware, so this block is shared by
// every FIPS 202 operation used by ML-DSA-65 and ML-KEM-768.

module lca_keccak_f1600 (
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         zeroize_i,

    input  wire         start_i,
    output reg          busy_o,
    output reg          done_o,

    input  wire         state_we_i,
    input  wire [5:0]   state_word_addr_i,
    input  wire [31:0]  state_wdata_i,
    input  wire [3:0]   state_wstrb_i,
    output reg  [31:0]  state_rdata_o
);

    reg [63:0] state_q [0:24];
    reg [63:0] state_d [0:24];
    reg [63:0] theta_c [0:4];
    reg [63:0] theta_d [0:4];
    reg [63:0] theta_a [0:24];
    reg [63:0] rho_pi_b [0:24];
    reg [4:0]  round_q;

    integer x;
    integer y;
    integer lane;
    integer dst_x;
    integer dst_y;
    integer i;

    function automatic [63:0] rotl64;
        input [63:0] value;
        input integer amount;
        begin
            if (amount == 0)
                rotl64 = value;
            else
                rotl64 = (value << amount) | (value >> (64 - amount));
        end
    endfunction

    function automatic integer rho_offset;
        input integer lane_index;
        begin
            case (lane_index)
                0:  rho_offset = 0;
                1:  rho_offset = 1;
                2:  rho_offset = 62;
                3:  rho_offset = 28;
                4:  rho_offset = 27;
                5:  rho_offset = 36;
                6:  rho_offset = 44;
                7:  rho_offset = 6;
                8:  rho_offset = 55;
                9:  rho_offset = 20;
                10: rho_offset = 3;
                11: rho_offset = 10;
                12: rho_offset = 43;
                13: rho_offset = 25;
                14: rho_offset = 39;
                15: rho_offset = 41;
                16: rho_offset = 45;
                17: rho_offset = 15;
                18: rho_offset = 21;
                19: rho_offset = 8;
                20: rho_offset = 18;
                21: rho_offset = 2;
                22: rho_offset = 61;
                23: rho_offset = 56;
                24: rho_offset = 14;
                default: rho_offset = 0;
            endcase
        end
    endfunction

    function automatic [63:0] round_constant;
        input [4:0] round_index;
        begin
            case (round_index)
                5'd0:  round_constant = 64'h0000000000000001;
                5'd1:  round_constant = 64'h0000000000008082;
                5'd2:  round_constant = 64'h800000000000808a;
                5'd3:  round_constant = 64'h8000000080008000;
                5'd4:  round_constant = 64'h000000000000808b;
                5'd5:  round_constant = 64'h0000000080000001;
                5'd6:  round_constant = 64'h8000000080008081;
                5'd7:  round_constant = 64'h8000000000008009;
                5'd8:  round_constant = 64'h000000000000008a;
                5'd9:  round_constant = 64'h0000000000000088;
                5'd10: round_constant = 64'h0000000080008009;
                5'd11: round_constant = 64'h000000008000000a;
                5'd12: round_constant = 64'h000000008000808b;
                5'd13: round_constant = 64'h800000000000008b;
                5'd14: round_constant = 64'h8000000000008089;
                5'd15: round_constant = 64'h8000000000008003;
                5'd16: round_constant = 64'h8000000000008002;
                5'd17: round_constant = 64'h8000000000000080;
                5'd18: round_constant = 64'h000000000000800a;
                5'd19: round_constant = 64'h800000008000000a;
                5'd20: round_constant = 64'h8000000080008081;
                5'd21: round_constant = 64'h8000000000008080;
                5'd22: round_constant = 64'h0000000080000001;
                5'd23: round_constant = 64'h8000000080008008;
                default: round_constant = 64'd0;
            endcase
        end
    endfunction

    // Keccak state indexing is x + 5*y. The rho table above follows that
    // ordering. Pi maps B[y, 2*x+3*y] = ROT(A[x,y], rho[x,y]).
    always @* begin
        for (i = 0; i < 25; i = i + 1) begin
            state_d[i] = state_q[i];
            theta_a[i] = 64'd0;
            rho_pi_b[i] = 64'd0;
        end

        for (x = 0; x < 5; x = x + 1) begin
            theta_c[x] = state_q[x] ^ state_q[x + 5] ^ state_q[x + 10] ^
                         state_q[x + 15] ^ state_q[x + 20];
        end
        for (x = 0; x < 5; x = x + 1)
            theta_d[x] = theta_c[(x + 4) % 5] ^ rotl64(theta_c[(x + 1) % 5], 1);

        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                lane = x + 5*y;
                theta_a[lane] = state_q[lane] ^ theta_d[x];
            end
        end

        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                lane = x + 5*y;
                dst_x = y;
                dst_y = (2*x + 3*y) % 5;
                rho_pi_b[dst_x + 5*dst_y] = rotl64(theta_a[lane], rho_offset(lane));
            end
        end

        for (y = 0; y < 5; y = y + 1) begin
            for (x = 0; x < 5; x = x + 1) begin
                lane = x + 5*y;
                state_d[lane] = rho_pi_b[lane] ^
                    ((~rho_pi_b[((x + 1) % 5) + 5*y]) &
                       rho_pi_b[((x + 2) % 5) + 5*y]);
            end
        end
        state_d[0] = state_d[0] ^ round_constant(round_q);
    end

    always @* begin
        if (state_word_addr_i[0] == 1'b0)
            state_rdata_o = state_q[state_word_addr_i[5:1]][31:0];
        else
            state_rdata_o = state_q[state_word_addr_i[5:1]][63:32];
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            busy_o  <= 1'b0;
            done_o  <= 1'b0;
            round_q <= 5'd0;
            for (i = 0; i < 25; i = i + 1)
                state_q[i] <= 64'd0;
        end else if (zeroize_i) begin
            busy_o  <= 1'b0;
            done_o  <= 1'b0;
            round_q <= 5'd0;
            for (i = 0; i < 25; i = i + 1)
                state_q[i] <= 64'd0;
        end else begin
            if (state_we_i && !busy_o && state_word_addr_i < 6'd50) begin
                if (state_word_addr_i[0] == 1'b0) begin
                    if (state_wstrb_i[0]) state_q[state_word_addr_i[5:1]][7:0]   <= state_wdata_i[7:0];
                    if (state_wstrb_i[1]) state_q[state_word_addr_i[5:1]][15:8]  <= state_wdata_i[15:8];
                    if (state_wstrb_i[2]) state_q[state_word_addr_i[5:1]][23:16] <= state_wdata_i[23:16];
                    if (state_wstrb_i[3]) state_q[state_word_addr_i[5:1]][31:24] <= state_wdata_i[31:24];
                end else begin
                    if (state_wstrb_i[0]) state_q[state_word_addr_i[5:1]][39:32] <= state_wdata_i[7:0];
                    if (state_wstrb_i[1]) state_q[state_word_addr_i[5:1]][47:40] <= state_wdata_i[15:8];
                    if (state_wstrb_i[2]) state_q[state_word_addr_i[5:1]][55:48] <= state_wdata_i[23:16];
                    if (state_wstrb_i[3]) state_q[state_word_addr_i[5:1]][63:56] <= state_wdata_i[31:24];
                end
            end

            if (start_i && !busy_o) begin
                busy_o  <= 1'b1;
                done_o  <= 1'b0;
                round_q <= 5'd0;
            end else if (busy_o) begin
                for (i = 0; i < 25; i = i + 1)
                    state_q[i] <= state_d[i];
                if (round_q == 5'd23) begin
                    busy_o <= 1'b0;
                    done_o <= 1'b1;
                end else begin
                    round_q <= round_q + 1'b1;
                end
            end
        end
    end

endmodule
