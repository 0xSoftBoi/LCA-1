// SPDX-License-Identifier: Apache-2.0
//
// Bounded Rev-A integration core for the ChipFoundry OpenFrame shell.
//
// This is deliberately not the legacy firmware/CPU prototype in
// rtl/lca_chip_top.sv. Rev-A is a host-driven accelerator with a 16-bit
// LCA-LINK request/response interface, 32 KiB secure SRAM, NTT/INTT, and
// Keccak-f[1600]. No management CPU, mutable firmware, USB, PLL, or protocol
// stack is included at this boundary.

`default_nettype none

module lca_reva_core #(
    parameter integer SRAM_WORDS = 8192
) (
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         tamper_n_i,
    input  wire         zeroize_req_i,
    input  wire [31:0]  mask_rev_i,

    input  wire [15:0]  host_d_i,
    output wire [15:0]  host_d_o,
    output wire         host_d_oe_o,
    input  wire [7:0]   host_addr_i,
    input  wire         req_valid_i,
    output wire         req_ready_o,
    input  wire         req_write_i,
    input  wire         req_last_i,
    output wire         rsp_valid_o,
    input  wire         rsp_ready_i,
    output wire         rsp_last_o,

    output wire         irq_o,
    output wire         busy_o,
    output wire         fault_o,
    output wire         zeroize_busy_o,
    output wire         selftest_fail_o
);

    localparam integer SRAM_ADDR_W = $clog2(SRAM_WORDS);
    localparam integer SRAM_BYTES  = SRAM_WORDS * 4;

    // Rev-A halfword CSR map.
    localparam [7:0] CSR_ID_LO          = 8'h00;
    localparam [7:0] CSR_ID_HI          = 8'h01;
    localparam [7:0] CSR_ABI_VERSION    = 8'h02;
    localparam [7:0] CSR_CAPABILITIES   = 8'h03;
    localparam [7:0] CSR_STATUS         = 8'h04;
    localparam [7:0] CSR_ERROR_CODE     = 8'h05;
    localparam [7:0] CSR_COMMAND        = 8'h06;
    localparam [7:0] CSR_CONTROL        = 8'h07;
    localparam [7:0] CSR_STREAM_LO      = 8'h08;
    localparam [7:0] CSR_STREAM_HI      = 8'h09;
    localparam [7:0] CSR_TRANSFER_LO    = 8'h0a;
    localparam [7:0] CSR_TRANSFER_HI    = 8'h0b;
    localparam [7:0] CSR_SELFTEST       = 8'h0c;
    localparam [7:0] CSR_MASK_REV_LO    = 8'h0d;
    localparam [7:0] CSR_MASK_REV_HI    = 8'h0e;

    // Sequential data channels. Bit zero is reserved for a one-byte final
    // beat; the even address names the channel.
    localparam [7:0] CH_NTT_WRITE       = 8'h80;
    localparam [7:0] CH_NTT_READ        = 8'h82;
    localparam [7:0] CH_KECCAK_WRITE    = 8'h84;
    localparam [7:0] CH_KECCAK_READ     = 8'h86;
    localparam [7:0] CH_SRAM_WRITE      = 8'h88;
    localparam [7:0] CH_SRAM_READ       = 8'h8a;

    localparam [7:0] CMD_MLKEM_NTT      = 8'h00;
    localparam [7:0] CMD_MLKEM_INTT     = 8'h01;
    localparam [7:0] CMD_MLDSA_NTT      = 8'h02;
    localparam [7:0] CMD_MLDSA_INTT     = 8'h03;
    localparam [7:0] CMD_KECCAK_F1600   = 8'h04;
    localparam [7:0] CMD_MOD_ARITH      = 8'h05;
    localparam [7:0] CMD_SRAM_WIPE      = 8'h06;
    localparam [7:0] CMD_SELF_TEST      = 8'h07;

    localparam [15:0] ERR_NONE          = 16'h0000;
    localparam [15:0] ERR_ILLEGAL_ADDR  = 16'h0001;
    localparam [15:0] ERR_ILLEGAL_CMD   = 16'h0002;
    localparam [15:0] ERR_BUSY          = 16'h0003;
    localparam [15:0] ERR_LENGTH        = 16'h0004;
    localparam [15:0] ERR_PROTOCOL      = 16'h0005;
    localparam [15:0] ERR_SELFTEST      = 16'h0006;
    localparam [15:0] ERR_TAMPER        = 16'h0007;

    localparam [3:0] ST_SELF_IDLE       = 4'd0;
    localparam [3:0] ST_SELF_WAIT_SCRUB = 4'd1;
    localparam [3:0] ST_SELF_WAIT_NTT   = 4'd2;
    localparam [3:0] ST_SELF_CHECK_NTT  = 4'd3;
    localparam [3:0] ST_SELF_WAIT_KEC   = 4'd4;
    localparam [3:0] ST_SELF_CHECK_K0   = 4'd5;
    localparam [3:0] ST_SELF_CHECK_K1   = 4'd6;

    wire [7:0] channel = {host_addr_i[7:1], 1'b0};
    wire       one_byte_beat = host_addr_i[0];
    wire       req_fire;

    reg  [15:0] rsp_data_q;
    reg         rsp_valid_q;
    reg         rsp_last_q;

    reg         init_done_q;
    reg         zeroize_active_q;
    reg         zeroize_seen_q;
    reg         tamper_seen_q;
    reg [SRAM_ADDR_W-1:0] scrub_addr_q;

    reg         irq_q;
    reg         fault_q;
    reg         done_q;
    reg         selftest_fail_q;
    reg  [15:0] error_code_q;
    reg  [7:0]  command_q;
    reg  [31:0] stream_cursor_q;
    reg  [31:0] transfer_count_q;

    reg  [10:0] ntt_write_cursor_q;
    reg  [10:0] ntt_read_cursor_q;
    reg  [10:0] ntt_staged_len_q;
    reg  [8:0]  keccak_write_cursor_q;
    reg  [8:0]  keccak_read_cursor_q;
    reg  [8:0]  keccak_staged_len_q;
    reg  [15:0] sram_write_cursor_q;
    reg  [15:0] sram_read_cursor_q;
    reg  [15:0] sram_staged_len_q;

    reg         ntt_start_q;
    reg  [1:0]  ntt_command_q;
    reg         ntt_host_active_q;
    wire        ntt_busy;
    wire        ntt_done;

    reg         keccak_start_q;
    reg         keccak_host_active_q;
    wire        keccak_busy;
    wire        keccak_done;

    reg  [3:0]  selftest_state_q;
    reg         selftest_zeroize_pulse_q;
    reg         selftest_seen_ntt_busy_q;

    wire selftest_busy = selftest_state_q != ST_SELF_IDLE;
    wire engine_zeroize = zeroize_active_q || selftest_zeroize_pulse_q;

    assign host_d_o       = rsp_data_q;
    assign host_d_oe_o    = rsp_valid_q;
    assign rsp_valid_o    = rsp_valid_q;
    assign rsp_last_o     = rsp_last_q;
    assign irq_o          = irq_q;
    assign fault_o        = fault_q;
    assign zeroize_busy_o = zeroize_active_q;
    assign selftest_fail_o = selftest_fail_q;
    assign busy_o         = zeroize_active_q || ntt_busy || keccak_busy || selftest_busy;

    // The host is held off until the mandatory power-on SRAM scrub completes.
    // A physically asserted tamper or external zeroize input also prevents any
    // new request from being accepted until it is released.
    assign req_ready_o = init_done_q && !zeroize_active_q && tamper_n_i &&
                         !zeroize_req_i && !rsp_valid_q;
    assign req_fire = req_valid_i && req_ready_o;

    function automatic [31:0] beat_wdata;
        input [15:0] data;
        input        upper_half;
        input        one_byte;
        begin
            if (upper_half) begin
                if (one_byte)
                    beat_wdata = {8'd0, data[7:0], 16'd0};
                else
                    beat_wdata = {data, 16'd0};
            end else begin
                if (one_byte)
                    beat_wdata = {24'd0, data[7:0]};
                else
                    beat_wdata = {16'd0, data};
            end
        end
    endfunction

    function automatic [3:0] beat_wstrb;
        input upper_half;
        input one_byte;
        begin
            if (upper_half)
                beat_wstrb = one_byte ? 4'b0100 : 4'b1100;
            else
                beat_wstrb = one_byte ? 4'b0001 : 4'b0011;
        end
    endfunction

    function automatic [1:0] map_ntt_command;
        input [7:0] cmd;
        begin
            case (cmd)
                CMD_MLDSA_NTT:  map_ntt_command = 2'd0;
                CMD_MLDSA_INTT: map_ntt_command = 2'd1;
                CMD_MLKEM_NTT:  map_ntt_command = 2'd2;
                default:        map_ntt_command = 2'd3;
            endcase
        end
    endfunction

    function automatic [15:0] csr_read;
        input [7:0] address;
        begin
            case (address)
                CSR_ID_LO:        csr_read = 16'h4131; // identity 0x4c434131
                CSR_ID_HI:        csr_read = 16'h4c43;
                CSR_ABI_VERSION:  csr_read = 16'h0001;
                CSR_CAPABILITIES: csr_read = 16'h00df; // NTTx4, Keccak, wipe, self-test
                CSR_STATUS:       csr_read = {
                    9'd0,
                    irq_q,
                    selftest_fail_q,
                    zeroize_active_q,
                    fault_q,
                    done_q,
                    busy_o,
                    init_done_q
                };
                CSR_ERROR_CODE:   csr_read = error_code_q;
                CSR_COMMAND:      csr_read = {8'd0, command_q};
                CSR_CONTROL:      csr_read = 16'd0;
                CSR_STREAM_LO:    csr_read = stream_cursor_q[15:0];
                CSR_STREAM_HI:    csr_read = stream_cursor_q[31:16];
                CSR_TRANSFER_LO:  csr_read = transfer_count_q[15:0];
                CSR_TRANSFER_HI:  csr_read = transfer_count_q[31:16];
                CSR_SELFTEST:     csr_read = {14'd0, selftest_fail_q, selftest_busy};
                CSR_MASK_REV_LO:  csr_read = mask_rev_i[15:0];
                CSR_MASK_REV_HI:  csr_read = mask_rev_i[31:16];
                default:          csr_read = 16'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // NTT coefficient window
    // ------------------------------------------------------------------

    wire ntt_write_fire = req_fire && req_write_i &&
                          (channel == CH_NTT_WRITE) && !busy_o &&
                          (!one_byte_beat || req_last_i) &&
                          (ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) <= 11'd1024);

    wire [7:0] ntt_host_addr = ntt_write_fire ? ntt_write_cursor_q[9:2] :
                                ntt_read_cursor_q[9:2];
    wire [31:0] ntt_host_wdata = beat_wdata(
        host_d_i, ntt_write_cursor_q[1], one_byte_beat
    );
    wire [3:0] ntt_host_wstrb = beat_wstrb(ntt_write_cursor_q[1], one_byte_beat);
    wire [31:0] ntt_coeff_rdata;

    lca_ntt_accel u_ntt (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(engine_zeroize),
        .start_i(ntt_start_q),
        .command_i(ntt_command_q),
        .busy_o(ntt_busy),
        .done_o(ntt_done),
        .coeff_we_i(ntt_write_fire),
        .coeff_addr_i((selftest_state_q == ST_SELF_CHECK_NTT) ? 8'd0 : ntt_host_addr),
        .coeff_wdata_i(ntt_host_wdata),
        .coeff_wstrb_i(ntt_host_wstrb),
        .coeff_rdata_o(ntt_coeff_rdata)
    );

    // ------------------------------------------------------------------
    // Keccak state window
    // ------------------------------------------------------------------

    wire keccak_write_fire = req_fire && req_write_i &&
                             (channel == CH_KECCAK_WRITE) && !busy_o &&
                             (!one_byte_beat || req_last_i) &&
                             (keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) <= 9'd200);
    wire [5:0] keccak_host_addr = keccak_write_cursor_q[7:2];
    wire [31:0] keccak_host_wdata = beat_wdata(
        host_d_i, keccak_write_cursor_q[1], one_byte_beat
    );
    wire [3:0] keccak_host_wstrb = beat_wstrb(keccak_write_cursor_q[1], one_byte_beat);
    reg  [5:0] keccak_read_addr_mux;
    wire [31:0] keccak_state_rdata;

    always @* begin
        if (selftest_state_q == ST_SELF_CHECK_K0)
            keccak_read_addr_mux = 6'd0;
        else if (selftest_state_q == ST_SELF_CHECK_K1)
            keccak_read_addr_mux = 6'd1;
        else if (keccak_write_fire)
            keccak_read_addr_mux = keccak_host_addr;
        else
            keccak_read_addr_mux = keccak_read_cursor_q[7:2];
    end

    lca_keccak_f1600 u_keccak (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(engine_zeroize),
        .start_i(keccak_start_q),
        .busy_o(keccak_busy),
        .done_o(keccak_done),
        .state_we_i(keccak_write_fire),
        .state_word_addr_i(keccak_write_fire ? keccak_host_addr : keccak_read_addr_mux),
        .state_wdata_i(keccak_host_wdata),
        .state_wstrb_i(keccak_host_wstrb),
        .state_rdata_o(keccak_state_rdata)
    );

    // ------------------------------------------------------------------
    // 32 KiB secure SRAM boundary
    // ------------------------------------------------------------------

    wire sram_write_fire = req_fire && req_write_i &&
                           (channel == CH_SRAM_WRITE) && !busy_o &&
                           (!one_byte_beat || req_last_i) &&
                           (sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2) <= SRAM_BYTES);
    wire [SRAM_ADDR_W-1:0] sram_stream_waddr = sram_write_cursor_q[SRAM_ADDR_W+1:2];
    wire [SRAM_ADDR_W-1:0] sram_stream_raddr = sram_read_cursor_q[SRAM_ADDR_W+1:2];
    wire [31:0] sram_stream_wdata = beat_wdata(
        host_d_i, sram_write_cursor_q[1], one_byte_beat
    );
    wire [3:0] sram_stream_wstrb = beat_wstrb(sram_write_cursor_q[1], one_byte_beat);
    reg [SRAM_ADDR_W-1:0] sram_waddr_mux;
    reg [31:0] sram_wdata_mux;
    reg [3:0] sram_wstrb_mux;
    wire [31:0] sram_rdata;

    always @* begin
        sram_waddr_mux = sram_stream_waddr;
        sram_wdata_mux = sram_stream_wdata;
        sram_wstrb_mux = sram_write_fire ? sram_stream_wstrb : 4'b0000;
        if (zeroize_active_q) begin
            sram_waddr_mux = scrub_addr_q;
            sram_wdata_mux = 32'd0;
            sram_wstrb_mux = 4'b1111;
        end
    end

    lca_secure_sram #(
        .WORDS(SRAM_WORDS),
        .ADDR_W(SRAM_ADDR_W)
    ) u_secure_sram (
        .clk_i(clk_i),
        .raddr_i(sram_stream_raddr),
        .rdata_o(sram_rdata),
        .waddr_i(sram_waddr_mux),
        .wdata_i(sram_wdata_mux),
        .wstrb_i(sram_wstrb_mux)
    );

    // A control ABORT or ZEROIZE request is handled before the normal CSR
    // write path, so it cannot race the self-test or an active accelerator.
    wire control_wipe_fire = req_fire && req_write_i &&
                             (host_addr_i == CSR_CONTROL) &&
                             (host_d_i[1] || host_d_i[2]);

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rsp_data_q               <= 16'd0;
            rsp_valid_q              <= 1'b0;
            rsp_last_q               <= 1'b0;
            init_done_q              <= 1'b0;
            zeroize_active_q         <= 1'b1;
            zeroize_seen_q           <= 1'b0;
            tamper_seen_q            <= 1'b0;
            scrub_addr_q             <= {SRAM_ADDR_W{1'b0}};
            irq_q                    <= 1'b0;
            fault_q                  <= 1'b0;
            done_q                   <= 1'b0;
            selftest_fail_q          <= 1'b1;
            error_code_q             <= ERR_NONE;
            command_q                <= CMD_SELF_TEST;
            stream_cursor_q          <= 32'd0;
            transfer_count_q         <= 32'd0;
            ntt_write_cursor_q       <= 11'd0;
            ntt_read_cursor_q        <= 11'd0;
            ntt_staged_len_q         <= 11'd0;
            keccak_write_cursor_q    <= 9'd0;
            keccak_read_cursor_q     <= 9'd0;
            keccak_staged_len_q      <= 9'd0;
            sram_write_cursor_q      <= 16'd0;
            sram_read_cursor_q       <= 16'd0;
            sram_staged_len_q        <= 16'd0;
            ntt_start_q              <= 1'b0;
            ntt_command_q            <= 2'd2;
            ntt_host_active_q        <= 1'b0;
            keccak_start_q           <= 1'b0;
            keccak_host_active_q     <= 1'b0;
            selftest_state_q         <= ST_SELF_IDLE;
            selftest_zeroize_pulse_q <= 1'b0;
            selftest_seen_ntt_busy_q <= 1'b0;
        end else begin
            ntt_start_q              <= 1'b0;
            keccak_start_q           <= 1'b0;
            selftest_zeroize_pulse_q <= 1'b0;

            if (!zeroize_req_i)
                zeroize_seen_q <= 1'b0;
            if (tamper_n_i)
                tamper_seen_q <= 1'b0;

            if (rsp_valid_q && rsp_ready_i)
                rsp_valid_q <= 1'b0;

            // Power-on and explicit global zeroization have highest priority.
            if (zeroize_active_q) begin
                if (zeroize_req_i)
                    zeroize_seen_q <= 1'b1;
                if (!tamper_n_i) begin
                    tamper_seen_q <= 1'b1;
                    fault_q <= 1'b1;
                    error_code_q <= ERR_TAMPER;
                end

                if (scrub_addr_q == SRAM_WORDS - 1) begin
                    scrub_addr_q     <= {SRAM_ADDR_W{1'b0}};
                    zeroize_active_q <= 1'b0;
                    init_done_q      <= 1'b1;
                end else begin
                    scrub_addr_q <= scrub_addr_q + 1'b1;
                end
            end else if ((!tamper_n_i && !tamper_seen_q) ||
                         (zeroize_req_i && !zeroize_seen_q)) begin
                zeroize_active_q         <= 1'b1;
                scrub_addr_q             <= {SRAM_ADDR_W{1'b0}};
                rsp_valid_q              <= 1'b0;
                rsp_data_q               <= 16'd0;
                done_q                   <= 1'b0;
                irq_q                    <= 1'b0;
                ntt_host_active_q        <= 1'b0;
                keccak_host_active_q     <= 1'b0;
                selftest_state_q         <= ST_SELF_IDLE;
                selftest_zeroize_pulse_q <= 1'b0;
                ntt_write_cursor_q       <= 11'd0;
                ntt_read_cursor_q        <= 11'd0;
                ntt_staged_len_q         <= 11'd0;
                keccak_write_cursor_q    <= 9'd0;
                keccak_read_cursor_q     <= 9'd0;
                keccak_staged_len_q      <= 9'd0;
                sram_write_cursor_q      <= 16'd0;
                sram_read_cursor_q       <= 16'd0;
                sram_staged_len_q        <= 16'd0;
                stream_cursor_q          <= 32'd0;
                transfer_count_q         <= 32'd0;
                if (!tamper_n_i) begin
                    tamper_seen_q <= 1'b1;
                    fault_q <= 1'b1;
                    error_code_q <= ERR_TAMPER;
                end else begin
                    zeroize_seen_q <= 1'b1;
                end
            end else if (control_wipe_fire) begin
                // A host-requested abort/zeroize receives a non-secret ack,
                // then the core immediately enters the full scrub state.
                rsp_data_q               <= 16'd0;
                rsp_valid_q              <= 1'b1;
                rsp_last_q               <= 1'b1;
                zeroize_active_q         <= 1'b1;
                scrub_addr_q             <= {SRAM_ADDR_W{1'b0}};
                done_q                   <= 1'b0;
                irq_q                    <= 1'b0;
                ntt_host_active_q        <= 1'b0;
                keccak_host_active_q     <= 1'b0;
                selftest_state_q         <= ST_SELF_IDLE;
                ntt_write_cursor_q       <= 11'd0;
                ntt_read_cursor_q        <= 11'd0;
                ntt_staged_len_q         <= 11'd0;
                keccak_write_cursor_q    <= 9'd0;
                keccak_read_cursor_q     <= 9'd0;
                keccak_staged_len_q      <= 9'd0;
                sram_write_cursor_q      <= 16'd0;
                sram_read_cursor_q       <= 16'd0;
                sram_staged_len_q        <= 16'd0;
                stream_cursor_q          <= 32'd0;
                transfer_count_q         <= 32'd0;
            end else begin
                // Completion IRQs are sticky and only generated for host-
                // launched operations, not the internal self-test sequence.
                if (ntt_host_active_q && ntt_done) begin
                    ntt_host_active_q <= 1'b0;
                    done_q <= 1'b1;
                    irq_q <= 1'b1;
                end
                if (keccak_host_active_q && keccak_done) begin
                    keccak_host_active_q <= 1'b0;
                    done_q <= 1'b1;
                    irq_q <= 1'b1;
                end

                // Built-in self-test: clear both engines, run an all-zero
                // ML-KEM NTT (zero must remain zero), then Keccak-f[1600](0)
                // and compare lane zero against the published permutation
                // constant F1258F7940E1DDE7.
                case (selftest_state_q)
                    ST_SELF_WAIT_SCRUB: begin
                        if (ntt_busy)
                            selftest_seen_ntt_busy_q <= 1'b1;
                        if (selftest_seen_ntt_busy_q && !ntt_busy) begin
                            ntt_command_q <= 2'd2;
                            ntt_start_q <= 1'b1;
                            selftest_state_q <= ST_SELF_WAIT_NTT;
                        end
                    end
                    ST_SELF_WAIT_NTT: begin
                        if (ntt_done)
                            selftest_state_q <= ST_SELF_CHECK_NTT;
                    end
                    ST_SELF_CHECK_NTT: begin
                        if (ntt_coeff_rdata != 32'd0) begin
                            selftest_fail_q <= 1'b1;
                            fault_q <= 1'b1;
                            error_code_q <= ERR_SELFTEST;
                            done_q <= 1'b1;
                            irq_q <= 1'b1;
                            selftest_state_q <= ST_SELF_IDLE;
                        end else begin
                            keccak_start_q <= 1'b1;
                            selftest_state_q <= ST_SELF_WAIT_KEC;
                        end
                    end
                    ST_SELF_WAIT_KEC: begin
                        if (keccak_done)
                            selftest_state_q <= ST_SELF_CHECK_K0;
                    end
                    ST_SELF_CHECK_K0: begin
                        if (keccak_state_rdata != 32'h40e1dde7) begin
                            selftest_fail_q <= 1'b1;
                            fault_q <= 1'b1;
                            error_code_q <= ERR_SELFTEST;
                            done_q <= 1'b1;
                            irq_q <= 1'b1;
                            selftest_state_q <= ST_SELF_IDLE;
                        end else begin
                            selftest_state_q <= ST_SELF_CHECK_K1;
                        end
                    end
                    ST_SELF_CHECK_K1: begin
                        if (keccak_state_rdata != 32'hf1258f79) begin
                            selftest_fail_q <= 1'b1;
                            fault_q <= 1'b1;
                            error_code_q <= ERR_SELFTEST;
                        end else begin
                            selftest_fail_q <= 1'b0;
                            error_code_q <= ERR_NONE;
                        end
                        done_q <= 1'b1;
                        irq_q <= 1'b1;
                        selftest_state_q <= ST_SELF_IDLE;
                    end
                    default: begin end
                endcase

                if (req_fire) begin
                    rsp_data_q  <= 16'd0;
                    rsp_valid_q <= 1'b1;
                    rsp_last_q  <= 1'b1;

                    if (!req_write_i) begin
                        if (host_addr_i <= CSR_MASK_REV_HI) begin
                            rsp_data_q <= csr_read(host_addr_i);
                        end else begin
                            case (channel)
                                CH_NTT_READ: begin
                                    if (busy_o || ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) > 11'd1024) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= busy_o ? ERR_BUSY : ERR_LENGTH;
                                        rsp_data_q <= 16'd0;
                                    end else begin
                                        if (ntt_read_cursor_q[1])
                                            rsp_data_q <= one_byte_beat ? {8'd0, ntt_coeff_rdata[23:16]} : ntt_coeff_rdata[31:16];
                                        else
                                            rsp_data_q <= one_byte_beat ? {8'd0, ntt_coeff_rdata[7:0]} : ntt_coeff_rdata[15:0];
                                        rsp_last_q <= (ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) == 11'd1024);
                                        stream_cursor_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        transfer_count_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        if (ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) == 11'd1024)
                                            ntt_read_cursor_q <= 11'd0;
                                        else
                                            ntt_read_cursor_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                    end
                                end
                                CH_KECCAK_READ: begin
                                    if (busy_o || keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) > 9'd200) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= busy_o ? ERR_BUSY : ERR_LENGTH;
                                        rsp_data_q <= 16'd0;
                                    end else begin
                                        if (keccak_read_cursor_q[1])
                                            rsp_data_q <= one_byte_beat ? {8'd0, keccak_state_rdata[23:16]} : keccak_state_rdata[31:16];
                                        else
                                            rsp_data_q <= one_byte_beat ? {8'd0, keccak_state_rdata[7:0]} : keccak_state_rdata[15:0];
                                        rsp_last_q <= (keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200);
                                        stream_cursor_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        transfer_count_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        if (keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200)
                                            keccak_read_cursor_q <= 9'd0;
                                        else
                                            keccak_read_cursor_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                    end
                                end
                                CH_SRAM_READ: begin
                                    if (busy_o || sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2) > SRAM_BYTES) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= busy_o ? ERR_BUSY : ERR_LENGTH;
                                        rsp_data_q <= 16'd0;
                                    end else begin
                                        if (sram_read_cursor_q[1])
                                            rsp_data_q <= one_byte_beat ? {8'd0, sram_rdata[23:16]} : sram_rdata[31:16];
                                        else
                                            rsp_data_q <= one_byte_beat ? {8'd0, sram_rdata[7:0]} : sram_rdata[15:0];
                                        rsp_last_q <= req_last_i;
                                        stream_cursor_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        transfer_count_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        if (req_last_i)
                                            sram_read_cursor_q <= 16'd0;
                                        else
                                            sram_read_cursor_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                    end
                                end
                                default: begin
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_ILLEGAL_ADDR;
                                    rsp_data_q <= 16'd0;
                                end
                            endcase
                        end
                    end else begin
                        if (host_addr_i <= CSR_MASK_REV_HI) begin
                            case (host_addr_i)
                                CSR_COMMAND: begin
                                    if (busy_o) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_BUSY;
                                    end else begin
                                        command_q <= host_d_i[7:0];
                                    end
                                end
                                CSR_CONTROL: begin
                                    if (host_d_i[3]) done_q <= 1'b0;
                                    if (host_d_i[4]) irq_q <= 1'b0;
                                    if (host_d_i[5] && tamper_n_i) begin
                                        fault_q <= 1'b0;
                                        error_code_q <= ERR_NONE;
                                    end
                                    if (host_d_i[6]) begin
                                        ntt_write_cursor_q <= 11'd0;
                                        ntt_read_cursor_q <= 11'd0;
                                        ntt_staged_len_q <= 11'd0;
                                        keccak_write_cursor_q <= 9'd0;
                                        keccak_read_cursor_q <= 9'd0;
                                        keccak_staged_len_q <= 9'd0;
                                        sram_write_cursor_q <= 16'd0;
                                        sram_read_cursor_q <= 16'd0;
                                        sram_staged_len_q <= 16'd0;
                                        stream_cursor_q <= 32'd0;
                                        transfer_count_q <= 32'd0;
                                    end

                                    if (host_d_i[0]) begin
                                        if (busy_o) begin
                                            fault_q <= 1'b1;
                                            error_code_q <= ERR_BUSY;
                                        end else begin
                                            done_q <= 1'b0;
                                            irq_q <= 1'b0;
                                            case (command_q)
                                                CMD_MLKEM_NTT,
                                                CMD_MLKEM_INTT,
                                                CMD_MLDSA_NTT,
                                                CMD_MLDSA_INTT: begin
                                                    if (ntt_staged_len_q != 11'd1024) begin
                                                        fault_q <= 1'b1;
                                                        error_code_q <= ERR_LENGTH;
                                                    end else begin
                                                        ntt_command_q <= map_ntt_command(command_q);
                                                        ntt_start_q <= 1'b1;
                                                        ntt_host_active_q <= 1'b1;
                                                    end
                                                end
                                                CMD_KECCAK_F1600: begin
                                                    if (keccak_staged_len_q != 9'd200) begin
                                                        fault_q <= 1'b1;
                                                        error_code_q <= ERR_LENGTH;
                                                    end else begin
                                                        keccak_start_q <= 1'b1;
                                                        keccak_host_active_q <= 1'b1;
                                                    end
                                                end
                                                CMD_SRAM_WIPE: begin
                                                    zeroize_active_q <= 1'b1;
                                                    scrub_addr_q <= {SRAM_ADDR_W{1'b0}};
                                                end
                                                CMD_SELF_TEST: begin
                                                    selftest_fail_q <= 1'b1;
                                                    selftest_seen_ntt_busy_q <= 1'b0;
                                                    selftest_zeroize_pulse_q <= 1'b1;
                                                    selftest_state_q <= ST_SELF_WAIT_SCRUB;
                                                end
                                                CMD_MOD_ARITH: begin
                                                    // The primitive remains in the Rev-A RTL set, but the
                                                    // LCA-LINK operand/result ABI is not yet frozen.
                                                    fault_q <= 1'b1;
                                                    error_code_q <= ERR_ILLEGAL_CMD;
                                                end
                                                default: begin
                                                    fault_q <= 1'b1;
                                                    error_code_q <= ERR_ILLEGAL_CMD;
                                                end
                                            endcase
                                        end
                                    end
                                end
                                default: begin
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_ILLEGAL_ADDR;
                                end
                            endcase
                        end else begin
                            case (channel)
                                CH_NTT_WRITE: begin
                                    if (busy_o) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_BUSY;
                                    end else if (one_byte_beat && !req_last_i) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_PROTOCOL;
                                        ntt_write_cursor_q <= 11'd0;
                                        ntt_staged_len_q <= 11'd0;
                                    end else if (ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) > 11'd1024) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_LENGTH;
                                        ntt_write_cursor_q <= 11'd0;
                                        ntt_staged_len_q <= 11'd0;
                                    end else if (req_last_i !=
                                                 (ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) == 11'd1024)) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_LENGTH;
                                        ntt_write_cursor_q <= 11'd0;
                                        ntt_staged_len_q <= 11'd0;
                                    end else begin
                                        stream_cursor_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        transfer_count_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        if (req_last_i) begin
                                            ntt_staged_len_q <= 11'd1024;
                                            ntt_write_cursor_q <= 11'd0;
                                            rsp_last_q <= 1'b1;
                                        end else begin
                                            ntt_write_cursor_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                            rsp_last_q <= 1'b0;
                                        end
                                    end
                                end
                                CH_KECCAK_WRITE: begin
                                    if (busy_o) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_BUSY;
                                    end else if (one_byte_beat && !req_last_i) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_PROTOCOL;
                                        keccak_write_cursor_q <= 9'd0;
                                        keccak_staged_len_q <= 9'd0;
                                    end else if (keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) > 9'd200) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_LENGTH;
                                        keccak_write_cursor_q <= 9'd0;
                                        keccak_staged_len_q <= 9'd0;
                                    end else if (req_last_i !=
                                                 (keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200)) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_LENGTH;
                                        keccak_write_cursor_q <= 9'd0;
                                        keccak_staged_len_q <= 9'd0;
                                    end else begin
                                        stream_cursor_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        transfer_count_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        if (req_last_i) begin
                                            keccak_staged_len_q <= 9'd200;
                                            keccak_write_cursor_q <= 9'd0;
                                            rsp_last_q <= 1'b1;
                                        end else begin
                                            keccak_write_cursor_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                            rsp_last_q <= 1'b0;
                                        end
                                    end
                                end
                                CH_SRAM_WRITE: begin
                                    if (busy_o) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_BUSY;
                                    end else if (one_byte_beat && !req_last_i) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_PROTOCOL;
                                        sram_write_cursor_q <= 16'd0;
                                        sram_staged_len_q <= 16'd0;
                                    end else if (sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2) > SRAM_BYTES) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_LENGTH;
                                        sram_write_cursor_q <= 16'd0;
                                        sram_staged_len_q <= 16'd0;
                                    end else begin
                                        stream_cursor_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        transfer_count_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        if (req_last_i) begin
                                            sram_staged_len_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                            sram_write_cursor_q <= 16'd0;
                                            rsp_last_q <= 1'b1;
                                        end else begin
                                            sram_write_cursor_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                            rsp_last_q <= 1'b0;
                                        end
                                    end
                                end
                                default: begin
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_ILLEGAL_ADDR;
                                end
                            endcase
                        end
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
