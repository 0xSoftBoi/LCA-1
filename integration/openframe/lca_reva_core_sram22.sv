// SPDX-License-Identifier: Apache-2.0
//
// Physical Rev-A core using the pinned synchronous SRAM22 memory architecture.
//
// Unlike lca_reva_core, this module speaks the frozen LCA-LINK-16 fabrication
// ABI directly and models registered SRAM/NTT reads honestly. It is intended
// for LCA_PHYSICAL_SRAM22 OpenFrame hardening; the older bounded core remains
// the behavioral/reference implementation.

`default_nettype none

module lca_reva_core_sram22 (
`ifdef USE_POWER_PINS
    inout wire         vdd,
    inout wire         vss,
`endif
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
    localparam integer SRAM_BYTES = 32768;

    localparam [7:0] CSR_ID_LO        = 8'h00;
    localparam [7:0] CSR_ID_HI        = 8'h01;
    localparam [7:0] CSR_ABI_VERSION  = 8'h02;
    localparam [7:0] CSR_CAPABILITIES = 8'h03;
    localparam [7:0] CSR_STATUS       = 8'h04;
    localparam [7:0] CSR_ERROR_CODE   = 8'h05;
    localparam [7:0] CSR_COMMAND      = 8'h06;
    localparam [7:0] CSR_CONTROL      = 8'h07;
    localparam [7:0] CSR_STREAM_LO    = 8'h08;
    localparam [7:0] CSR_STREAM_HI    = 8'h09;
    localparam [7:0] CSR_TRANSFER_LO  = 8'h0a;
    localparam [7:0] CSR_TRANSFER_HI  = 8'h0b;
    localparam [7:0] CSR_SELFTEST     = 8'h0c;
    localparam [7:0] CSR_MASK_REV_LO  = 8'h0d;
    localparam [7:0] CSR_MASK_REV_HI  = 8'h0e;

    localparam [7:0] CH_NTT_WRITE     = 8'h80;
    localparam [7:0] CH_NTT_READ      = 8'h82;
    localparam [7:0] CH_KECCAK_WRITE  = 8'h84;
    localparam [7:0] CH_KECCAK_READ   = 8'h86;
    localparam [7:0] CH_SRAM_WRITE    = 8'h88;
    localparam [7:0] CH_SRAM_READ     = 8'h8a;

    // Frozen external command values.
    localparam [15:0] CMD_MLKEM_NTT    = 16'h0001;
    localparam [15:0] CMD_MLKEM_INTT   = 16'h0002;
    localparam [15:0] CMD_MLDSA_NTT    = 16'h0003;
    localparam [15:0] CMD_MLDSA_INTT   = 16'h0004;
    localparam [15:0] CMD_KECCAK       = 16'h0010;
    localparam [15:0] CMD_MOD_ARITH    = 16'h0020;
    localparam [15:0] CMD_SELF_TEST    = 16'h007f;

    localparam [15:0] ERR_NONE          = 16'h0000;
    localparam [15:0] ERR_ILLEGAL_ADDR  = 16'h0001;
    localparam [15:0] ERR_ILLEGAL_CMD   = 16'h0002;
    localparam [15:0] ERR_BUSY          = 16'h0003;
    localparam [15:0] ERR_LENGTH        = 16'h0004;
    localparam [15:0] ERR_PROTOCOL      = 16'h0005;
    localparam [15:0] ERR_SELFTEST      = 16'h0006;
    localparam [15:0] ERR_ZEROIZE       = 16'h0007;
    localparam [15:0] ERR_TAMPER        = 16'h0008;
    localparam [15:0] ERR_INTERNAL      = 16'h0009;

    localparam [3:0] SELF_IDLE          = 4'd0;
    localparam [3:0] SELF_WAIT_NTT_CLR  = 4'd1;
    localparam [3:0] SELF_WAIT_NTT      = 4'd2;
    localparam [3:0] SELF_READ_NTT      = 4'd3;
    localparam [3:0] SELF_CHECK_NTT     = 4'd4;
    localparam [3:0] SELF_WAIT_KECCAK   = 4'd5;
    localparam [3:0] SELF_CHECK_K0      = 4'd6;
    localparam [3:0] SELF_CHECK_K1      = 4'd7;

    wire [7:0] channel = {host_addr_i[7:1], 1'b0};
    wire one_byte_beat = host_addr_i[0];

    reg [15:0] rsp_data_q;
    reg        rsp_valid_q;
    reg        rsp_last_q;
    reg        irq_q;
    reg        fault_q;
    reg        done_q;
    reg [15:0] error_code_q;
    reg [15:0] command_q;
    reg [31:0] stream_cursor_q;
    reg [31:0] transfer_count_q;
    reg        selftest_fail_q;

    reg [10:0] ntt_write_cursor_q;
    reg [10:0] ntt_read_cursor_q;
    reg [10:0] ntt_staged_len_q;
    reg [8:0]  keccak_write_cursor_q;
    reg [8:0]  keccak_read_cursor_q;
    reg [8:0]  keccak_staged_len_q;
    reg [15:0] sram_write_cursor_q;
    reg [15:0] sram_read_cursor_q;
    reg [15:0] sram_staged_len_q;

    // ------------------------------------------------------------------
    // Global zeroize orchestration
    // ------------------------------------------------------------------
    reg boot_scrub_pending_q;
    reg zeroize_active_q;
    reg zeroize_launch_q;
    reg ntt_zeroize_seen_busy_q;
    reg sram_zeroize_seen_busy_q;
    reg zeroize_input_seen_q;
    reg tamper_seen_q;
    reg boot_complete_q;

    wire engine_zeroize_pulse = zeroize_launch_q;

    // ------------------------------------------------------------------
    // SRAM22-backed NTT
    // ------------------------------------------------------------------
    reg ntt_start_q;
    reg [1:0] ntt_command_q;
    reg ntt_host_active_q;
    wire ntt_busy;
    wire ntt_done;
    reg ntt_coeff_we_q;
    reg [7:0] ntt_coeff_addr_q;
    reg [31:0] ntt_coeff_wdata_q;
    reg [3:0] ntt_coeff_wstrb_q;
    wire [31:0] ntt_coeff_rdata;
    reg ntt_read_pending_q;
    reg ntt_read_one_byte_q;
    reg ntt_read_upper_q;
    reg ntt_read_last_q;

    function automatic [1:0] map_ntt_command;
        input [15:0] cmd;
        begin
            case (cmd)
                CMD_MLDSA_NTT:  map_ntt_command = 2'd0;
                CMD_MLDSA_INTT: map_ntt_command = 2'd1;
                CMD_MLKEM_NTT:  map_ntt_command = 2'd2;
                default:        map_ntt_command = 2'd3;
            endcase
        end
    endfunction

    lca_ntt_accel_sram22 u_ntt (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk_i(clk_i), .rst_ni(rst_ni), .zeroize_i(engine_zeroize_pulse),
        .start_i(ntt_start_q), .command_i(ntt_command_q),
        .busy_o(ntt_busy), .done_o(ntt_done),
        .coeff_we_i(ntt_coeff_we_q), .coeff_addr_i(ntt_coeff_addr_q),
        .coeff_wdata_i(ntt_coeff_wdata_q), .coeff_wstrb_i(ntt_coeff_wstrb_q),
        .coeff_rdata_o(ntt_coeff_rdata)
    );

    // ------------------------------------------------------------------
    // Keccak
    // ------------------------------------------------------------------
    reg keccak_start_q;
    reg keccak_host_active_q;
    wire keccak_busy;
    wire keccak_done;
    reg keccak_state_we_q;
    reg [5:0] keccak_state_addr_q;
    reg [31:0] keccak_state_wdata_q;
    reg [3:0] keccak_state_wstrb_q;
    wire [31:0] keccak_state_rdata;

    lca_keccak_f1600 u_keccak (
        .clk_i(clk_i), .rst_ni(rst_ni),
        .zeroize_i(zeroize_active_q || (selftest_state_q == SELF_WAIT_NTT_CLR)),
        .start_i(keccak_start_q), .busy_o(keccak_busy), .done_o(keccak_done),
        .state_we_i(keccak_state_we_q), .state_word_addr_i(keccak_state_addr_q),
        .state_wdata_i(keccak_state_wdata_q), .state_wstrb_i(keccak_state_wstrb_q),
        .state_rdata_o(keccak_state_rdata)
    );

    // ------------------------------------------------------------------
    // Four-bank SRAM22 secure SRAM
    // ------------------------------------------------------------------
    reg sram_zeroize_q;
    wire sram_zeroize_busy;
    reg sram_req_valid_q;
    wire sram_req_ready;
    reg sram_req_write_q;
    reg [12:0] sram_req_addr_q;
    reg [31:0] sram_req_wdata_q;
    reg [3:0] sram_req_wstrb_q;
    wire sram_rsp_valid;
    wire [31:0] sram_rsp_rdata;
    wire sram_rsp_ready = !rsp_valid_q;
    reg sram_host_pending_q;
    reg sram_host_read_q;
    reg sram_host_one_byte_q;
    reg sram_host_upper_q;
    reg sram_host_last_q;

    lca_secure_sram_sram22 u_secure_sram (
`ifdef USE_POWER_PINS
        .vdd(vdd), .vss(vss),
`endif
        .clk_i(clk_i), .rst_ni(rst_ni), .zeroize_i(sram_zeroize_q),
        .zeroize_busy_o(sram_zeroize_busy),
        .req_valid_i(sram_req_valid_q), .req_ready_o(sram_req_ready),
        .req_write_i(sram_req_write_q), .req_addr_i(sram_req_addr_q),
        .req_wdata_i(sram_req_wdata_q), .req_wstrb_i(sram_req_wstrb_q),
        .rsp_valid_o(sram_rsp_valid), .rsp_ready_i(sram_rsp_ready),
        .rsp_rdata_o(sram_rsp_rdata)
    );

    // ------------------------------------------------------------------
    // Built-in self-test
    // ------------------------------------------------------------------
    reg [3:0] selftest_state_q;
    reg selftest_ntt_seen_busy_q;

    wire selftest_busy = selftest_state_q != SELF_IDLE;
    assign busy_o = zeroize_active_q || ntt_busy || keccak_busy || selftest_busy;
    assign irq_o = irq_q;
    assign fault_o = fault_q;
    assign zeroize_busy_o = zeroize_active_q;
    assign selftest_fail_o = selftest_fail_q;
    assign host_d_o = rsp_data_q;
    assign host_d_oe_o = rsp_valid_q;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_last_o = rsp_last_q;

    wire backend_pending = ntt_read_pending_q || sram_host_pending_q;
    assign req_ready_o = boot_complete_q && !zeroize_active_q && tamper_n_i &&
                         !zeroize_req_i && !rsp_valid_q && !backend_pending;
    wire req_fire = req_valid_i && req_ready_o;

    function automatic [31:0] beat_wdata;
        input [15:0] data;
        input        upper_half;
        input        one_byte;
        begin
            if (upper_half)
                beat_wdata = one_byte ? {8'd0, data[7:0], 16'd0} : {data, 16'd0};
            else
                beat_wdata = one_byte ? {24'd0, data[7:0]} : {16'd0, data};
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

    function automatic [15:0] select_halfword;
        input [31:0] word;
        input upper_half;
        input one_byte;
        begin
            if (upper_half)
                select_halfword = one_byte ? {8'd0, word[23:16]} : word[31:16];
            else
                select_halfword = one_byte ? {8'd0, word[7:0]} : word[15:0];
        end
    endfunction

    function automatic [15:0] csr_read;
        input [7:0] address;
        begin
            case (address)
                CSR_ID_LO:        csr_read = 16'h4131;
                CSR_ID_HI:        csr_read = 16'h4c43;
                CSR_ABI_VERSION:  csr_read = 16'h0001;
                CSR_CAPABILITIES: csr_read = 16'h00df;
                CSR_STATUS:       csr_read = {9'd0, irq_q, selftest_fail_q, zeroize_active_q,
                                              fault_q, done_q, busy_o, boot_complete_q};
                CSR_ERROR_CODE:   csr_read = error_code_q;
                CSR_COMMAND:      csr_read = command_q;
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

    task automatic launch_zeroize;
        begin
            zeroize_active_q <= 1'b1;
            zeroize_launch_q <= 1'b1;
            sram_zeroize_q <= 1'b1;
            ntt_zeroize_seen_busy_q <= 1'b0;
            sram_zeroize_seen_busy_q <= 1'b0;
            rsp_valid_q <= 1'b0;
            ntt_read_pending_q <= 1'b0;
            sram_host_pending_q <= 1'b0;
            ntt_host_active_q <= 1'b0;
            keccak_host_active_q <= 1'b0;
            selftest_state_q <= SELF_IDLE;
            done_q <= 1'b0;
            irq_q <= 1'b0;
        end
    endtask

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rsp_data_q <= 16'd0;
            rsp_valid_q <= 1'b0;
            rsp_last_q <= 1'b0;
            irq_q <= 1'b0;
            fault_q <= 1'b0;
            done_q <= 1'b0;
            error_code_q <= ERR_NONE;
            command_q <= CMD_MLKEM_NTT;
            stream_cursor_q <= 32'd0;
            transfer_count_q <= 32'd0;
            selftest_fail_q <= 1'b1;
            ntt_write_cursor_q <= 11'd0;
            ntt_read_cursor_q <= 11'd0;
            ntt_staged_len_q <= 11'd0;
            keccak_write_cursor_q <= 9'd0;
            keccak_read_cursor_q <= 9'd0;
            keccak_staged_len_q <= 9'd0;
            sram_write_cursor_q <= 16'd0;
            sram_read_cursor_q <= 16'd0;
            sram_staged_len_q <= 16'd0;
            boot_scrub_pending_q <= 1'b1;
            zeroize_active_q <= 1'b0;
            zeroize_launch_q <= 1'b0;
            ntt_zeroize_seen_busy_q <= 1'b0;
            sram_zeroize_seen_busy_q <= 1'b0;
            zeroize_input_seen_q <= 1'b0;
            tamper_seen_q <= 1'b0;
            boot_complete_q <= 1'b0;
            ntt_start_q <= 1'b0;
            ntt_command_q <= 2'd2;
            ntt_host_active_q <= 1'b0;
            ntt_coeff_we_q <= 1'b0;
            ntt_coeff_addr_q <= 8'd0;
            ntt_coeff_wdata_q <= 32'd0;
            ntt_coeff_wstrb_q <= 4'd0;
            ntt_read_pending_q <= 1'b0;
            ntt_read_one_byte_q <= 1'b0;
            ntt_read_upper_q <= 1'b0;
            ntt_read_last_q <= 1'b0;
            keccak_start_q <= 1'b0;
            keccak_host_active_q <= 1'b0;
            keccak_state_we_q <= 1'b0;
            keccak_state_addr_q <= 6'd0;
            keccak_state_wdata_q <= 32'd0;
            keccak_state_wstrb_q <= 4'd0;
            sram_zeroize_q <= 1'b0;
            sram_req_valid_q <= 1'b0;
            sram_req_write_q <= 1'b0;
            sram_req_addr_q <= 13'd0;
            sram_req_wdata_q <= 32'd0;
            sram_req_wstrb_q <= 4'd0;
            sram_host_pending_q <= 1'b0;
            sram_host_read_q <= 1'b0;
            sram_host_one_byte_q <= 1'b0;
            sram_host_upper_q <= 1'b0;
            sram_host_last_q <= 1'b0;
            selftest_state_q <= SELF_IDLE;
            selftest_ntt_seen_busy_q <= 1'b0;
        end else begin
            ntt_start_q <= 1'b0;
            ntt_coeff_we_q <= 1'b0;
            ntt_coeff_wstrb_q <= 4'd0;
            keccak_start_q <= 1'b0;
            keccak_state_we_q <= 1'b0;
            keccak_state_wstrb_q <= 4'd0;
            sram_req_valid_q <= 1'b0;
            zeroize_launch_q <= 1'b0;
            sram_zeroize_q <= 1'b0;

            if (!zeroize_req_i)
                zeroize_input_seen_q <= 1'b0;
            if (tamper_n_i)
                tamper_seen_q <= 1'b0;
            if (rsp_valid_q && rsp_ready_i)
                rsp_valid_q <= 1'b0;

            if (boot_scrub_pending_q && !zeroize_active_q) begin
                boot_scrub_pending_q <= 1'b0;
                launch_zeroize();
            end else if ((!tamper_n_i && !tamper_seen_q) ||
                         (zeroize_req_i && !zeroize_input_seen_q)) begin
                if (!tamper_n_i) begin
                    tamper_seen_q <= 1'b1;
                    fault_q <= 1'b1;
                    error_code_q <= ERR_TAMPER;
                end else begin
                    zeroize_input_seen_q <= 1'b1;
                end
                launch_zeroize();
            end else if (zeroize_active_q) begin
                if (ntt_busy)
                    ntt_zeroize_seen_busy_q <= 1'b1;
                if (sram_zeroize_busy)
                    sram_zeroize_seen_busy_q <= 1'b1;
                if (ntt_zeroize_seen_busy_q && sram_zeroize_seen_busy_q &&
                    !ntt_busy && !sram_zeroize_busy) begin
                    zeroize_active_q <= 1'b0;
                    boot_complete_q <= 1'b1;
                    stream_cursor_q <= 32'd0;
                    transfer_count_q <= 32'd0;
                    ntt_write_cursor_q <= 11'd0;
                    ntt_read_cursor_q <= 11'd0;
                    ntt_staged_len_q <= 11'd0;
                    keccak_write_cursor_q <= 9'd0;
                    keccak_read_cursor_q <= 9'd0;
                    keccak_staged_len_q <= 9'd0;
                    sram_write_cursor_q <= 16'd0;
                    sram_read_cursor_q <= 16'd0;
                    sram_staged_len_q <= 16'd0;
                end
            end else begin
                // Delayed NTT host read response.
                if (ntt_read_pending_q && !rsp_valid_q) begin
                    rsp_data_q <= select_halfword(ntt_coeff_rdata, ntt_read_upper_q, ntt_read_one_byte_q);
                    rsp_valid_q <= 1'b1;
                    rsp_last_q <= ntt_read_last_q;
                    ntt_read_pending_q <= 1'b0;
                end

                // Secure SRAM fabric response.
                if (sram_host_pending_q && sram_rsp_valid && !rsp_valid_q) begin
                    rsp_data_q <= sram_host_read_q ?
                                  select_halfword(sram_rsp_rdata, sram_host_upper_q, sram_host_one_byte_q) : 16'd0;
                    rsp_valid_q <= 1'b1;
                    rsp_last_q <= sram_host_last_q;
                    sram_host_pending_q <= 1'b0;
                end

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

                // Self-test state machine. NTT/Keccak are zeroized first; an
                // all-zero ML-KEM forward NTT must remain zero and Keccak(0)
                // lane 0 must equal F1258F7940E1DDE7.
                case (selftest_state_q)
                    SELF_WAIT_NTT_CLR: begin
                        if (ntt_busy)
                            selftest_ntt_seen_busy_q <= 1'b1;
                        if (selftest_ntt_seen_busy_q && !ntt_busy) begin
                            ntt_command_q <= 2'd2;
                            ntt_start_q <= 1'b1;
                            selftest_state_q <= SELF_WAIT_NTT;
                        end
                    end
                    SELF_WAIT_NTT: begin
                        if (ntt_done) begin
                            ntt_coeff_addr_q <= 8'd0;
                            selftest_state_q <= SELF_READ_NTT;
                        end
                    end
                    SELF_READ_NTT: selftest_state_q <= SELF_CHECK_NTT;
                    SELF_CHECK_NTT: begin
                        if (ntt_coeff_rdata != 32'd0) begin
                            selftest_fail_q <= 1'b1;
                            fault_q <= 1'b1;
                            error_code_q <= ERR_SELFTEST;
                            done_q <= 1'b1;
                            irq_q <= 1'b1;
                            selftest_state_q <= SELF_IDLE;
                        end else begin
                            keccak_state_addr_q <= 6'd0;
                            keccak_start_q <= 1'b1;
                            selftest_state_q <= SELF_WAIT_KECCAK;
                        end
                    end
                    SELF_WAIT_KECCAK: begin
                        if (keccak_done) begin
                            keccak_state_addr_q <= 6'd0;
                            selftest_state_q <= SELF_CHECK_K0;
                        end
                    end
                    SELF_CHECK_K0: begin
                        if (keccak_state_rdata != 32'h40e1dde7) begin
                            selftest_fail_q <= 1'b1;
                            fault_q <= 1'b1;
                            error_code_q <= ERR_SELFTEST;
                            done_q <= 1'b1;
                            irq_q <= 1'b1;
                            selftest_state_q <= SELF_IDLE;
                        end else begin
                            keccak_state_addr_q <= 6'd1;
                            selftest_state_q <= SELF_CHECK_K1;
                        end
                    end
                    SELF_CHECK_K1: begin
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
                        selftest_state_q <= SELF_IDLE;
                    end
                    default: begin end
                endcase

                if (req_fire) begin
                    rsp_data_q <= 16'd0;
                    rsp_last_q <= 1'b1;

                    if (!req_write_i) begin
                        if (host_addr_i <= CSR_MASK_REV_HI) begin
                            rsp_data_q <= csr_read(host_addr_i);
                            rsp_valid_q <= 1'b1;
                        end else begin
                            case (channel)
                                CH_NTT_READ: begin
                                    if (ntt_busy || ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) > 11'd1024) begin
                                        rsp_valid_q <= 1'b1;
                                        fault_q <= 1'b1;
                                        error_code_q <= ntt_busy ? ERR_BUSY : ERR_LENGTH;
                                    end else begin
                                        ntt_coeff_addr_q <= ntt_read_cursor_q[9:2];
                                        ntt_read_upper_q <= ntt_read_cursor_q[1];
                                        ntt_read_one_byte_q <= one_byte_beat;
                                        ntt_read_last_q <= (ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) == 11'd1024);
                                        ntt_read_pending_q <= 1'b1;
                                        transfer_count_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        stream_cursor_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                        if (ntt_read_last_q)
                                            ntt_read_cursor_q <= 11'd0;
                                        else
                                            ntt_read_cursor_q <= ntt_read_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                    end
                                end
                                CH_KECCAK_READ: begin
                                    if (keccak_busy || keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) > 9'd200) begin
                                        rsp_valid_q <= 1'b1;
                                        fault_q <= 1'b1;
                                        error_code_q <= keccak_busy ? ERR_BUSY : ERR_LENGTH;
                                    end else begin
                                        keccak_state_addr_q <= keccak_read_cursor_q[7:2];
                                        rsp_data_q <= select_halfword(keccak_state_rdata, keccak_read_cursor_q[1], one_byte_beat);
                                        rsp_valid_q <= 1'b1;
                                        rsp_last_q <= (keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200);
                                        transfer_count_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        stream_cursor_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                        if (keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200)
                                            keccak_read_cursor_q <= 9'd0;
                                        else
                                            keccak_read_cursor_q <= keccak_read_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                    end
                                end
                                CH_SRAM_READ: begin
                                    if (!sram_req_ready || sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2) > SRAM_BYTES) begin
                                        rsp_valid_q <= 1'b1;
                                        fault_q <= 1'b1;
                                        error_code_q <= !sram_req_ready ? ERR_BUSY : ERR_LENGTH;
                                    end else begin
                                        sram_req_valid_q <= 1'b1;
                                        sram_req_write_q <= 1'b0;
                                        sram_req_addr_q <= sram_read_cursor_q[14:2];
                                        sram_host_pending_q <= 1'b1;
                                        sram_host_read_q <= 1'b1;
                                        sram_host_one_byte_q <= one_byte_beat;
                                        sram_host_upper_q <= sram_read_cursor_q[1];
                                        sram_host_last_q <= req_last_i;
                                        transfer_count_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        stream_cursor_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        if (req_last_i)
                                            sram_read_cursor_q <= 16'd0;
                                        else
                                            sram_read_cursor_q <= sram_read_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                    end
                                end
                                default: begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_ILLEGAL_ADDR;
                                end
                            endcase
                        end
                    end else if (host_addr_i <= CSR_MASK_REV_HI) begin
                        rsp_valid_q <= 1'b1;
                        case (host_addr_i)
                            CSR_COMMAND: begin
                                if (busy_o) begin
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_BUSY;
                                end else begin
                                    command_q <= host_d_i;
                                end
                            end
                            CSR_CONTROL: begin
                                if (host_d_i[2] && !busy_o) begin
                                    done_q <= 1'b0;
                                    irq_q <= 1'b0;
                                    if (tamper_n_i) begin
                                        fault_q <= 1'b0;
                                        error_code_q <= ERR_NONE;
                                    end
                                end
                                if (host_d_i[4] && !busy_o) begin
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
                                if (host_d_i[1] || host_d_i[3]) begin
                                    launch_zeroize();
                                end else if (host_d_i[0]) begin
                                    if (busy_o) begin
                                        fault_q <= 1'b1;
                                        error_code_q <= ERR_BUSY;
                                    end else begin
                                        done_q <= 1'b0;
                                        irq_q <= 1'b0;
                                        case (command_q)
                                            CMD_MLKEM_NTT, CMD_MLKEM_INTT,
                                            CMD_MLDSA_NTT, CMD_MLDSA_INTT: begin
                                                if (ntt_staged_len_q != 11'd1024) begin
                                                    fault_q <= 1'b1;
                                                    error_code_q <= ERR_LENGTH;
                                                end else begin
                                                    ntt_command_q <= map_ntt_command(command_q);
                                                    ntt_start_q <= 1'b1;
                                                    ntt_host_active_q <= 1'b1;
                                                end
                                            end
                                            CMD_KECCAK: begin
                                                if (keccak_staged_len_q != 9'd200) begin
                                                    fault_q <= 1'b1;
                                                    error_code_q <= ERR_LENGTH;
                                                end else begin
                                                    keccak_start_q <= 1'b1;
                                                    keccak_host_active_q <= 1'b1;
                                                end
                                            end
                                            CMD_SELF_TEST: begin
                                                selftest_fail_q <= 1'b1;
                                                selftest_ntt_seen_busy_q <= 1'b0;
                                                zeroize_launch_q <= 1'b1;
                                                selftest_state_q <= SELF_WAIT_NTT_CLR;
                                            end
                                            CMD_MOD_ARITH: begin
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
                            CSR_STREAM_LO: stream_cursor_q[15:0] <= host_d_i;
                            CSR_STREAM_HI: stream_cursor_q[31:16] <= host_d_i;
                            default: begin
                                fault_q <= 1'b1;
                                error_code_q <= ERR_ILLEGAL_ADDR;
                            end
                        endcase
                    end else begin
                        case (channel)
                            CH_NTT_WRITE: begin
                                if (ntt_busy) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_BUSY;
                                end else if ((one_byte_beat && !req_last_i) ||
                                             ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) > 11'd1024 ||
                                             req_last_i != (ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2) == 11'd1024)) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= one_byte_beat && !req_last_i ? ERR_PROTOCOL : ERR_LENGTH;
                                    ntt_write_cursor_q <= 11'd0;
                                    ntt_staged_len_q <= 11'd0;
                                end else begin
                                    ntt_coeff_we_q <= 1'b1;
                                    ntt_coeff_addr_q <= ntt_write_cursor_q[9:2];
                                    ntt_coeff_wdata_q <= beat_wdata(host_d_i, ntt_write_cursor_q[1], one_byte_beat);
                                    ntt_coeff_wstrb_q <= beat_wstrb(ntt_write_cursor_q[1], one_byte_beat);
                                    rsp_valid_q <= 1'b1;
                                    rsp_last_q <= req_last_i;
                                    transfer_count_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                    stream_cursor_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                    if (req_last_i) begin
                                        ntt_staged_len_q <= 11'd1024;
                                        ntt_write_cursor_q <= 11'd0;
                                    end else begin
                                        ntt_write_cursor_q <= ntt_write_cursor_q + (one_byte_beat ? 11'd1 : 11'd2);
                                    end
                                end
                            end
                            CH_KECCAK_WRITE: begin
                                if (keccak_busy) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_BUSY;
                                end else if ((one_byte_beat && !req_last_i) ||
                                             keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) > 9'd200 ||
                                             req_last_i != (keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2) == 9'd200)) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= one_byte_beat && !req_last_i ? ERR_PROTOCOL : ERR_LENGTH;
                                    keccak_write_cursor_q <= 9'd0;
                                    keccak_staged_len_q <= 9'd0;
                                end else begin
                                    keccak_state_we_q <= 1'b1;
                                    keccak_state_addr_q <= keccak_write_cursor_q[7:2];
                                    keccak_state_wdata_q <= beat_wdata(host_d_i, keccak_write_cursor_q[1], one_byte_beat);
                                    keccak_state_wstrb_q <= beat_wstrb(keccak_write_cursor_q[1], one_byte_beat);
                                    rsp_valid_q <= 1'b1;
                                    rsp_last_q <= req_last_i;
                                    transfer_count_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                    stream_cursor_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                    if (req_last_i) begin
                                        keccak_staged_len_q <= 9'd200;
                                        keccak_write_cursor_q <= 9'd0;
                                    end else begin
                                        keccak_write_cursor_q <= keccak_write_cursor_q + (one_byte_beat ? 9'd1 : 9'd2);
                                    end
                                end
                            end
                            CH_SRAM_WRITE: begin
                                if (!sram_req_ready || sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2) > SRAM_BYTES) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= !sram_req_ready ? ERR_BUSY : ERR_LENGTH;
                                end else if (one_byte_beat && !req_last_i) begin
                                    rsp_valid_q <= 1'b1;
                                    fault_q <= 1'b1;
                                    error_code_q <= ERR_PROTOCOL;
                                end else begin
                                    sram_req_valid_q <= 1'b1;
                                    sram_req_write_q <= 1'b1;
                                    sram_req_addr_q <= sram_write_cursor_q[14:2];
                                    sram_req_wdata_q <= beat_wdata(host_d_i, sram_write_cursor_q[1], one_byte_beat);
                                    sram_req_wstrb_q <= beat_wstrb(sram_write_cursor_q[1], one_byte_beat);
                                    sram_host_pending_q <= 1'b1;
                                    sram_host_read_q <= 1'b0;
                                    sram_host_one_byte_q <= one_byte_beat;
                                    sram_host_upper_q <= sram_write_cursor_q[1];
                                    sram_host_last_q <= req_last_i;
                                    transfer_count_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                    stream_cursor_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                    if (req_last_i) begin
                                        sram_staged_len_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                        sram_write_cursor_q <= 16'd0;
                                    end else begin
                                        sram_write_cursor_q <= sram_write_cursor_q + (one_byte_beat ? 16'd1 : 16'd2);
                                    end
                                end
                            end
                            default: begin
                                rsp_valid_q <= 1'b1;
                                fault_q <= 1'b1;
                                error_code_q <= ERR_ILLEGAL_ADDR;
                            end
                        endcase
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
