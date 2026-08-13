// SPDX-License-Identifier: Apache-2.0
//
// LCA-1 Level-3 post-quantum bridge coprocessor top level.
//
// This is the portable digital integration boundary. Foundry pad cells, PLLs,
// SRAM/ROM macros, and the entropy source are supplied by the target wrapper.
// The inferred arrays below are intentionally simple so the same image runs
// in RTL simulation and on FPGA; an ASIC flow replaces them with compiled
// macros at this hierarchy.

module lca_chip_top #(
    parameter integer ROM_WORDS  = 65536,   // 256 KiB immutable firmware ROM
    parameter integer SRAM_WORDS = 131072,  // 512 KiB secure SRAM
    parameter         FIRMWARE_HEX = "build/firmware.hex"
) (
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         tamper_i,

    // APB4 host control plane.
    input  wire [11:0]  paddr_i,
    input  wire         psel_i,
    input  wire         penable_i,
    input  wire         pwrite_i,
    input  wire [31:0]  pwdata_i,
    input  wire [3:0]   pstrb_i,
    output wire [31:0]  prdata_o,
    output wire         pready_o,
    output wire         pslverr_o,

    // Tagged bulk-input stream.
    input  wire         s_valid_i,
    output wire         s_ready_o,
    input  wire [2:0]   s_kind_i,
    input  wire [31:0]  s_data_i,
    input  wire [3:0]   s_keep_i,
    input  wire         s_last_i,

    // Bulk output stream (32-byte ML-KEM shared secret).
    output wire         m_valid_o,
    input  wire         m_ready_i,
    output wire [31:0]  m_data_o,
    output wire [3:0]   m_keep_o,
    output wire         m_last_o,

    // Conditioned entropy supplied by the platform TRNG. Verification and
    // decapsulation are deterministic, but this port is reserved for masking,
    // self-test blinding, and future hardened firmware.
    input  wire         entropy_valid_i,
    output wire         entropy_ready_o,
    input  wire [31:0]  entropy_data_i,

    output wire         irq_o,
    output wire         busy_o,
    output wire         zeroize_busy_o,
    output wire         firmware_trap_o
);

    localparam integer SRAM_ADDR_W = $clog2(SRAM_WORDS);
    localparam [31:0] ROM_BASE      = 32'h0000_0000;
    localparam [31:0] SRAM_BASE     = 32'h1000_0000;
    localparam [31:0] MAILBOX_BASE  = 32'h2000_0000;
    localparam [31:0] KECCAK_BASE   = 32'h2000_1000;
    localparam [31:0] NTT_BASE      = 32'h2000_2000;
    localparam [31:0] ARITH_BASE    = 32'h2000_3000;

    localparam [31:0] SRAM_BYTES = SRAM_WORDS * 4;
    localparam [31:0] ROM_BYTES  = ROM_WORDS * 4;
    localparam [31:0] FW_STACK_TOP = SRAM_BASE + 32'h0006_0000;

    reg [31:0] firmware_rom [0:ROM_WORDS-1];

    initial begin
        $readmemh(FIRMWARE_HEX, firmware_rom);
    end

    // ---------------------------------------------------------------------
    // Host frontend and firmware mailbox
    // ---------------------------------------------------------------------

    wire dma_we;
    wire [SRAM_ADDR_W-1:0] dma_word_addr;
    wire [31:0] dma_wdata;
    wire [3:0] dma_wstrb;
    wire command_pending;
    wire [7:0] command;
    wire [31:0] message_len;
    wire [7:0] context_len;
    wire [5:0] loaded_mask;
    wire frontend_done;
    wire frontend_error;
    wire verify_valid;
    wire [7:0] frontend_result_code;
    wire frontend_zeroize_req;

    reg fw_claim;
    reg fw_result_we;
    reg [2:0] fw_result_index;
    reg [31:0] fw_result_data;
    reg fw_complete;
    reg [7:0] fw_result_code;
    reg [15:0] fw_result_len;
    reg [63:0] operation_cycles;

    wire zeroize_frontend;

    lca_host_frontend #(
        .SRAM_WORD_ADDR_W(SRAM_ADDR_W)
    ) u_host_frontend (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(zeroize_frontend),
        .paddr_i(paddr_i),
        .psel_i(psel_i),
        .penable_i(penable_i),
        .pwrite_i(pwrite_i),
        .pwdata_i(pwdata_i),
        .pstrb_i(pstrb_i),
        .prdata_o(prdata_o),
        .pready_o(pready_o),
        .pslverr_o(pslverr_o),
        .s_valid_i(s_valid_i),
        .s_ready_o(s_ready_o),
        .s_kind_i(s_kind_i),
        .s_data_i(s_data_i),
        .s_keep_i(s_keep_i),
        .s_last_i(s_last_i),
        .m_valid_o(m_valid_o),
        .m_ready_i(m_ready_i),
        .m_data_o(m_data_o),
        .m_keep_o(m_keep_o),
        .m_last_o(m_last_o),
        .dma_we_o(dma_we),
        .dma_word_addr_o(dma_word_addr),
        .dma_wdata_o(dma_wdata),
        .dma_wstrb_o(dma_wstrb),
        .command_pending_o(command_pending),
        .command_o(command),
        .message_len_o(message_len),
        .context_len_o(context_len),
        .loaded_mask_o(loaded_mask),
        .fw_claim_i(fw_claim),
        .fw_result_we_i(fw_result_we),
        .fw_result_index_i(fw_result_index),
        .fw_result_data_i(fw_result_data),
        .fw_complete_i(fw_complete),
        .fw_result_code_i(fw_result_code),
        .fw_result_len_i(fw_result_len),
        .cycle_count_i(operation_cycles),
        .busy_o(busy_o),
        .done_o(frontend_done),
        .error_o(frontend_error),
        .verify_valid_o(verify_valid),
        .result_code_o(frontend_result_code),
        .zeroize_req_o(frontend_zeroize_req),
        .irq_o(irq_o)
    );

    // ---------------------------------------------------------------------
    // SRAM zeroization controller
    // ---------------------------------------------------------------------

    reg zeroize_active;
    reg [SRAM_ADDR_W-1:0] scrub_addr;
    wire zeroize_trigger = tamper_i || frontend_zeroize_req;
    assign zeroize_busy_o = zeroize_active;
    assign zeroize_frontend = zeroize_active || zeroize_trigger;

    // ---------------------------------------------------------------------
    // Firmware CPU and memory bus
    // ---------------------------------------------------------------------

    wire cpu_resetn = rst_ni && !zeroize_active && !zeroize_trigger;
    wire cpu_trap;
    wire cpu_mem_valid;
    wire cpu_mem_instr;
    wire cpu_mem_ready;
    wire [31:0] cpu_mem_addr;
    wire [31:0] cpu_mem_wdata;
    wire [3:0] cpu_mem_wstrb;
    reg  [31:0] cpu_mem_rdata;

    wire cpu_is_rom = (cpu_mem_addr >= ROM_BASE) &&
                      (cpu_mem_addr < ROM_BASE + ROM_BYTES);
    wire cpu_is_sram = (cpu_mem_addr >= SRAM_BASE) &&
                       (cpu_mem_addr < SRAM_BASE + SRAM_BYTES);
    wire cpu_is_mailbox = (cpu_mem_addr[31:12] == MAILBOX_BASE[31:12]);
    wire cpu_is_keccak  = (cpu_mem_addr[31:12] == KECCAK_BASE[31:12]);
    wire cpu_is_ntt     = (cpu_mem_addr[31:12] == NTT_BASE[31:12]);
    wire cpu_is_arith   = (cpu_mem_addr[31:12] == ARITH_BASE[31:12]);
    wire cpu_write = cpu_mem_valid && (cpu_mem_wstrb != 4'b0000);
    wire [SRAM_ADDR_W-1:0] cpu_sram_word_addr =
        (cpu_mem_addr - SRAM_BASE) >> 2;

    // DMA gets priority only while the accelerator is idle. If a rare CPU
    // SRAM access collides with a host write, stall the CPU for that cycle.
    assign cpu_mem_ready = cpu_mem_valid && cpu_resetn &&
                           !(cpu_is_sram && dma_we);
    assign firmware_trap_o = cpu_trap;

    reg [SRAM_ADDR_W-1:0] sram_waddr;
    reg [31:0] sram_wdata;
    reg [3:0] sram_wstrb;
    wire [31:0] sram_rdata;

    always @* begin
        sram_waddr = cpu_sram_word_addr;
        sram_wdata = cpu_mem_wdata;
        sram_wstrb = 4'b0000;
        if (cpu_is_sram && cpu_write && cpu_mem_ready)
            sram_wstrb = cpu_mem_wstrb;
        if (dma_we) begin
            sram_waddr = dma_word_addr;
            sram_wdata = dma_wdata;
            sram_wstrb = dma_wstrb;
        end
        if (zeroize_active) begin
            sram_waddr = scrub_addr;
            sram_wdata = 32'd0;
            sram_wstrb = 4'b1111;
        end
    end

    lca_secure_sram #(
        .WORDS(SRAM_WORDS),
        .ADDR_W(SRAM_ADDR_W)
    ) u_secure_sram (
        .clk_i(clk_i),
        .raddr_i(cpu_sram_word_addr),
        .rdata_o(sram_rdata),
        .waddr_i(sram_waddr),
        .wdata_i(sram_wdata),
        .wstrb_i(sram_wstrb)
    );

    picorv32 #(
        .ENABLE_COUNTERS(1),
        .ENABLE_COUNTERS64(1),
        .ENABLE_REGS_16_31(1),
        .ENABLE_REGS_DUALPORT(1),
        .BARREL_SHIFTER(1),
        .TWO_CYCLE_COMPARE(0),
        .TWO_CYCLE_ALU(0),
        .COMPRESSED_ISA(1),
        .ENABLE_MUL(1),
        .ENABLE_FAST_MUL(0),
        .ENABLE_DIV(1),
        .ENABLE_IRQ(0),
        .CATCH_MISALIGN(1),
        .CATCH_ILLINSN(1),
        .REGS_INIT_ZERO(1),
        .PROGADDR_RESET(ROM_BASE),
        .STACKADDR(FW_STACK_TOP)
    ) u_firmware_cpu (
        .clk(clk_i),
        .resetn(cpu_resetn),
        .trap(cpu_trap),
        .mem_valid(cpu_mem_valid),
        .mem_instr(cpu_mem_instr),
        .mem_ready(cpu_mem_ready),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(cpu_mem_wstrb),
        .mem_rdata(cpu_mem_rdata),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0)
    );

    // ---------------------------------------------------------------------
    // Keccak-f[1600] peripheral
    // ---------------------------------------------------------------------

    wire [11:0] keccak_offset = cpu_mem_addr[11:0];
    wire keccak_control_write = cpu_is_keccak && cpu_write &&
                                 (keccak_offset == 12'h000);
    wire keccak_state_access = cpu_is_keccak &&
                                (keccak_offset >= 12'h100) &&
                                (keccak_offset < 12'h1c8);
    wire keccak_start = keccak_control_write && cpu_mem_wdata[0];
    wire keccak_local_zeroize = keccak_control_write && cpu_mem_wdata[1];
    wire keccak_busy;
    wire keccak_done;
    wire [31:0] keccak_rdata;
    wire [5:0] keccak_state_word_addr =
        (keccak_offset - 12'h100) >> 2;

    lca_keccak_f1600 u_keccak (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(zeroize_frontend || keccak_local_zeroize),
        .start_i(keccak_start),
        .busy_o(keccak_busy),
        .done_o(keccak_done),
        .state_we_i(keccak_state_access && cpu_write),
        .state_word_addr_i(keccak_state_word_addr),
        .state_wdata_i(cpu_mem_wdata),
        .state_wstrb_i(cpu_mem_wstrb),
        .state_rdata_o(keccak_rdata)
    );

    // ---------------------------------------------------------------------
    // Shared NTT peripheral
    // ---------------------------------------------------------------------

    wire [11:0] ntt_offset = cpu_mem_addr[11:0];
    wire ntt_control_write = cpu_is_ntt && cpu_write && (ntt_offset == 12'h000);
    wire ntt_coeff_access = cpu_is_ntt &&
                            (ntt_offset >= 12'h100) &&
                            (ntt_offset < 12'h500);
    wire ntt_start = ntt_control_write && cpu_mem_wdata[0];
    wire ntt_local_zeroize = ntt_control_write && cpu_mem_wdata[3];
    wire ntt_busy;
    wire ntt_done;
    wire [31:0] ntt_rdata;
    wire [7:0] ntt_coeff_addr = (ntt_offset - 12'h100) >> 2;

    lca_ntt_accel u_ntt (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .zeroize_i(zeroize_frontend || ntt_local_zeroize),
        .start_i(ntt_start),
        .command_i(cpu_mem_wdata[2:1]),
        .busy_o(ntt_busy),
        .done_o(ntt_done),
        .coeff_we_i(ntt_coeff_access && cpu_write),
        .coeff_addr_i(ntt_coeff_addr),
        .coeff_wdata_i(cpu_mem_wdata),
        .coeff_wstrb_i(cpu_mem_wstrb),
        .coeff_rdata_o(ntt_rdata)
    );

    // ---------------------------------------------------------------------
    // Characterized dual-modulus arithmetic lane
    // ---------------------------------------------------------------------

    reg [23:0] arith_a;
    reg [23:0] arith_b;
    reg [23:0] arith_zeta;
    reg        arith_mode_kem;
    reg [1:0]  arith_op;
    wire [23:0] arith_out0;
    wire [23:0] arith_out1;
    wire arith_busy;
    wire arith_done;
    wire arith_error;
    wire arith_start = cpu_is_arith && cpu_write &&
                       (cpu_mem_addr[11:0] == 12'h000) && cpu_mem_wdata[0];
    // A control write both configures and starts the lane. Bypass the
    // configuration flops for that edge so the command cannot launch with
    // the previous mode/opcode.
    wire arith_mode_active = arith_start ? cpu_mem_wdata[1] : arith_mode_kem;
    wire [1:0] arith_op_active = arith_start ? cpu_mem_wdata[3:2] : arith_op;

    lca_core u_arith_lane (
        .clk(clk_i),
        .rst_n(cpu_resetn),
        .start(arith_start),
        .mode_kem(arith_mode_active),
        .op(arith_op_active),
        .a(arith_a),
        .b(arith_b),
        .zeta(arith_zeta),
        .out0(arith_out0),
        .out1(arith_out1),
        .busy(arith_busy),
        .done(arith_done),
        .error(arith_error)
    );

    // ---------------------------------------------------------------------
    // Entropy holding register
    // ---------------------------------------------------------------------

    reg [31:0] entropy_word;
    reg entropy_word_valid;
    assign entropy_ready_o = !entropy_word_valid && !zeroize_active;

    // ---------------------------------------------------------------------
    // CPU read mux
    // ---------------------------------------------------------------------

    always @* begin
        cpu_mem_rdata = 32'h0000_0000;
        if (cpu_is_rom) begin
            cpu_mem_rdata = firmware_rom[(cpu_mem_addr - ROM_BASE) >> 2];
        end else if (cpu_is_sram) begin
            cpu_mem_rdata = sram_rdata;
        end else if (cpu_is_mailbox) begin
            case (cpu_mem_addr[11:2])
                10'h000: cpu_mem_rdata = {29'd0, busy_o, command_pending, 1'b1};
                10'h001: cpu_mem_rdata = {24'd0, command};
                10'h002: cpu_mem_rdata = message_len;
                10'h003: cpu_mem_rdata = {24'd0, context_len};
                10'h004: cpu_mem_rdata = {26'd0, loaded_mask};
                10'h005: cpu_mem_rdata = operation_cycles[31:0];
                10'h006: cpu_mem_rdata = operation_cycles[63:32];
                10'h007: cpu_mem_rdata = {31'd0, entropy_word_valid};
                10'h008: cpu_mem_rdata = entropy_word;
                10'h009: cpu_mem_rdata = 32'h0002_0000;
                default: cpu_mem_rdata = 32'd0;
            endcase
        end else if (cpu_is_keccak) begin
            if (keccak_state_access)
                cpu_mem_rdata = keccak_rdata;
            else
                cpu_mem_rdata = {30'd0, keccak_done, keccak_busy};
        end else if (cpu_is_ntt) begin
            if (ntt_coeff_access)
                cpu_mem_rdata = ntt_rdata;
            else
                cpu_mem_rdata = {30'd0, ntt_done, ntt_busy};
        end else if (cpu_is_arith) begin
            case (cpu_mem_addr[11:2])
                10'h000: cpu_mem_rdata = {24'd0, arith_error, arith_done,
                                           arith_busy, 2'd0, arith_op,
                                           arith_mode_kem};
                10'h001: cpu_mem_rdata = {8'd0, arith_a};
                10'h002: cpu_mem_rdata = {8'd0, arith_b};
                10'h003: cpu_mem_rdata = {8'd0, arith_zeta};
                10'h004: cpu_mem_rdata = {8'd0, arith_out0};
                10'h005: cpu_mem_rdata = {8'd0, arith_out1};
                default: cpu_mem_rdata = 32'd0;
            endcase
        end else begin
            cpu_mem_rdata = 32'hdead_beef;
        end
    end

    // ---------------------------------------------------------------------
    // Sequential control, mailbox writes, SRAM arbitration, and scrub
    // ---------------------------------------------------------------------

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            zeroize_active  <= 1'b0;
            scrub_addr      <= {SRAM_ADDR_W{1'b0}};
            fw_claim        <= 1'b0;
            fw_result_we    <= 1'b0;
            fw_result_index <= 3'd0;
            fw_result_data  <= 32'd0;
            fw_complete     <= 1'b0;
            fw_result_code  <= 8'd0;
            fw_result_len   <= 16'd0;
            operation_cycles <= 64'd0;
            arith_a         <= 24'd0;
            arith_b         <= 24'd0;
            arith_zeta      <= 24'd0;
            arith_mode_kem  <= 1'b0;
            arith_op        <= 2'd0;
            entropy_word    <= 32'd0;
            entropy_word_valid <= 1'b0;
        end else begin
            fw_claim     <= 1'b0;
            fw_result_we <= 1'b0;
            fw_complete  <= 1'b0;

            if (!busy_o)
                operation_cycles <= 64'd0;
            else
                operation_cycles <= operation_cycles + 1'b1;

            if (entropy_valid_i && entropy_ready_o) begin
                entropy_word <= entropy_data_i;
                entropy_word_valid <= 1'b1;
            end

            if (zeroize_trigger && !zeroize_active) begin
                zeroize_active <= 1'b1;
                scrub_addr <= {SRAM_ADDR_W{1'b0}};
                entropy_word <= 32'd0;
                entropy_word_valid <= 1'b0;
                fw_result_len <= 16'd0;
            end else if (zeroize_active) begin
                if (scrub_addr == SRAM_WORDS - 1) begin
                    zeroize_active <= 1'b0;
                    scrub_addr <= {SRAM_ADDR_W{1'b0}};
                end else begin
                    scrub_addr <= scrub_addr + 1'b1;
                end
            end else begin
                if (cpu_is_mailbox && cpu_write && cpu_mem_ready) begin
                    case (cpu_mem_addr[11:2])
                        10'h000: begin
                            if (cpu_mem_wdata[0])
                                fw_claim <= 1'b1;
                        end
                        10'h001: begin
                            fw_result_code <= cpu_mem_wdata[7:0];
                            fw_complete <= 1'b1;
                        end
                        10'h002: fw_result_len <= cpu_mem_wdata[15:0];
                        10'h010, 10'h011, 10'h012, 10'h013,
                        10'h014, 10'h015, 10'h016, 10'h017: begin
                            fw_result_we    <= 1'b1;
                            fw_result_index <= cpu_mem_addr[4:2];
                            fw_result_data  <= cpu_mem_wdata;
                        end
                        default: begin end
                    endcase
                end

                if (cpu_is_mailbox && cpu_mem_valid && !cpu_write &&
                    cpu_mem_ready && cpu_mem_addr[11:2] == 10'h008)
                    entropy_word_valid <= 1'b0;

                if (cpu_is_arith && cpu_write && cpu_mem_ready) begin
                    case (cpu_mem_addr[11:2])
                        10'h000: begin
                            arith_mode_kem <= cpu_mem_wdata[1];
                            arith_op       <= cpu_mem_wdata[3:2];
                        end
                        10'h001: arith_a    <= cpu_mem_wdata[23:0];
                        10'h002: arith_b    <= cpu_mem_wdata[23:0];
                        10'h003: arith_zeta <= cpu_mem_wdata[23:0];
                        default: begin end
                    endcase
                end
            end
        end
    end

    // Silence lint for status signals retained for debug visibility.
    wire _unused_status = &{1'b0, cpu_mem_instr, frontend_done,
                            frontend_error, verify_valid,
                            frontend_result_code[0]};

endmodule
