// SPDX-License-Identifier: Apache-2.0
//
// LCA-1 full-chip host interface.
//
// The control plane is APB4. Bulk inputs use a tagged, AXI-stream-like
// interface. The stream tag selects a fixed SRAM region and the frontend
// refuses to launch a command until every required object has its exact FIPS
// length. Variable-length message and context objects are bounded here.

module lca_host_frontend #(
    parameter integer SRAM_WORD_ADDR_W = 17,
    parameter integer PK_BASE_BYTE      = 32'h0006_0000,
    parameter integer SIG_BASE_BYTE     = 32'h0006_0800,
    parameter integer MSG_BASE_BYTE     = 32'h0006_1600,
    parameter integer CTX_BASE_BYTE     = 32'h0007_1600,
    parameter integer DK_BASE_BYTE      = 32'h0007_1700,
    parameter integer CT_BASE_BYTE      = 32'h0007_2080
) (
    input  wire                          clk_i,
    input  wire                          rst_ni,
    input  wire                          zeroize_i,

    // APB4 control/status slave.
    input  wire [11:0]                   paddr_i,
    input  wire                          psel_i,
    input  wire                          penable_i,
    input  wire                          pwrite_i,
    input  wire [31:0]                   pwdata_i,
    input  wire [3:0]                    pstrb_i,
    output reg  [31:0]                   prdata_o,
    output wire                          pready_o,
    output wire                          pslverr_o,

    // Tagged input stream. Tags are defined below as STREAM_*.
    input  wire                          s_valid_i,
    output wire                          s_ready_o,
    input  wire [2:0]                    s_kind_i,
    input  wire [31:0]                   s_data_i,
    input  wire [3:0]                    s_keep_i,
    input  wire                          s_last_i,

    // Shared-secret output stream. Verification has no bulk output.
    output wire                          m_valid_o,
    input  wire                          m_ready_i,
    output wire [31:0]                   m_data_o,
    output wire [3:0]                    m_keep_o,
    output wire                          m_last_o,

    // One write port into the shared SRAM, expressed as a word address.
    output wire                          dma_we_o,
    output wire [SRAM_WORD_ADDR_W-1:0]   dma_word_addr_o,
    output wire [31:0]                   dma_wdata_o,
    output wire [3:0]                    dma_wstrb_o,

    // Firmware mailbox view.
    output reg                           command_pending_o,
    output reg  [7:0]                    command_o,
    output reg  [31:0]                   message_len_o,
    output reg  [7:0]                    context_len_o,
    output reg  [5:0]                    loaded_mask_o,
    input  wire                          fw_claim_i,
    input  wire                          fw_result_we_i,
    input  wire [2:0]                    fw_result_index_i,
    input  wire [31:0]                   fw_result_data_i,
    input  wire                          fw_complete_i,
    input  wire [7:0]                    fw_result_code_i,
    input  wire [15:0]                   fw_result_len_i,

    input  wire [63:0]                   cycle_count_i,
    output reg                           busy_o,
    output reg                           done_o,
    output reg                           error_o,
    output reg                           verify_valid_o,
    output reg  [7:0]                    result_code_o,
    output reg                           zeroize_req_o,
    output wire                          irq_o
);

    localparam [7:0] CMD_NONE            = 8'h00;
    localparam [7:0] CMD_MLDSA65_VERIFY  = 8'h01;
    localparam [7:0] CMD_MLKEM768_DECAPS = 8'h02;
    localparam [7:0] CMD_SELF_TEST       = 8'h03;

    localparam [2:0] STREAM_MLDSA_PK  = 3'd0;
    localparam [2:0] STREAM_MLDSA_SIG = 3'd1;
    localparam [2:0] STREAM_MESSAGE   = 3'd2;
    localparam [2:0] STREAM_CONTEXT   = 3'd3;
    localparam [2:0] STREAM_MLKEM_DK  = 3'd4;
    localparam [2:0] STREAM_MLKEM_CT  = 3'd5;

    localparam integer MLDSA_PK_BYTES  = 1952;
    localparam integer MLDSA_SIG_BYTES = 3309;
    localparam integer MESSAGE_MAX     = 65536;
    localparam integer CONTEXT_MAX     = 255;
    localparam integer MLKEM_DK_BYTES  = 2400;
    localparam integer MLKEM_CT_BYTES  = 1088;

    localparam [7:0] RESULT_OK                = 8'h00;
    localparam [7:0] RESULT_INVALID_SIGNATURE = 8'h01;
    localparam [7:0] RESULT_BAD_COMMAND       = 8'h80;
    localparam [7:0] RESULT_INPUT_LENGTH      = 8'h81;
    localparam [7:0] RESULT_BUSY              = 8'h82;

    reg [7:0]  command_reg;
    reg [7:0]  active_command;
    reg [31:0] byte_count [0:5];
    reg        ingress_error;

    reg [31:0] result_words [0:7];
    reg [15:0] result_len_q;
    reg [2:0]  output_index;
    reg [5:0]  output_bytes_left;
    reg        output_active;

    integer i;
    reg [31:0] stream_base_byte;
    reg [31:0] stream_limit;
    reg [2:0]  keep_bytes;
    reg        keep_valid;
    reg        fixed_length;
    reg [31:0] stream_count;
    reg [31:0] next_count;

    wire apb_write = psel_i && penable_i && pwrite_i;
    wire stream_fire = s_valid_i && s_ready_o;

    // Every non-final beat must contain a whole word. Final partial words are
    // little-endian and therefore use a contiguous mask from bit zero.
    always @* begin
        keep_bytes = 3'd0;
        keep_valid = 1'b1;
        case (s_keep_i)
            4'b0000: keep_bytes = 3'd0;
            4'b0001: keep_bytes = 3'd1;
            4'b0011: keep_bytes = 3'd2;
            4'b0111: keep_bytes = 3'd3;
            4'b1111: keep_bytes = 3'd4;
            default: begin
                keep_bytes = 3'd0;
                keep_valid = 1'b0;
            end
        endcase
        if (!s_last_i && s_keep_i != 4'b1111)
            keep_valid = 1'b0;
        if (s_keep_i == 4'b0000)
            keep_valid = 1'b0;
    end

    always @* begin
        stream_base_byte = 32'd0;
        stream_limit = 32'd0;
        stream_count = 32'd0;
        fixed_length = 1'b1;
        case (s_kind_i)
            STREAM_MLDSA_PK: begin
                stream_base_byte = PK_BASE_BYTE;
                stream_limit = MLDSA_PK_BYTES;
                stream_count = byte_count[0];
            end
            STREAM_MLDSA_SIG: begin
                stream_base_byte = SIG_BASE_BYTE;
                stream_limit = MLDSA_SIG_BYTES;
                stream_count = byte_count[1];
            end
            STREAM_MESSAGE: begin
                stream_base_byte = MSG_BASE_BYTE;
                stream_limit = MESSAGE_MAX;
                stream_count = byte_count[2];
                fixed_length = 1'b0;
            end
            STREAM_CONTEXT: begin
                stream_base_byte = CTX_BASE_BYTE;
                stream_limit = CONTEXT_MAX;
                stream_count = byte_count[3];
                fixed_length = 1'b0;
            end
            STREAM_MLKEM_DK: begin
                stream_base_byte = DK_BASE_BYTE;
                stream_limit = MLKEM_DK_BYTES;
                stream_count = byte_count[4];
            end
            STREAM_MLKEM_CT: begin
                stream_base_byte = CT_BASE_BYTE;
                stream_limit = MLKEM_CT_BYTES;
                stream_count = byte_count[5];
            end
            default: begin
                stream_base_byte = 32'd0;
                stream_limit = 32'd0;
                fixed_length = 1'b1;
            end
        endcase
        next_count = stream_count + keep_bytes;
    end

    assign s_ready_o = rst_ni && !zeroize_i && !busy_o &&
                       (s_kind_i <= STREAM_MLKEM_CT);
    assign dma_we_o = stream_fire && keep_valid &&
                      (next_count <= stream_limit);
    assign dma_word_addr_o = (stream_base_byte + stream_count) >> 2;
    assign dma_wdata_o = s_data_i;
    assign dma_wstrb_o = s_keep_i;

    assign m_valid_o = output_active;
    assign m_data_o = result_words[output_index];
    assign m_keep_o = (output_bytes_left >= 6'd4) ? 4'b1111 :
                      (output_bytes_left == 6'd3) ? 4'b0111 :
                      (output_bytes_left == 6'd2) ? 4'b0011 :
                      (output_bytes_left == 6'd1) ? 4'b0001 : 4'b0000;
    assign m_last_o = output_active && (output_bytes_left <= 6'd4);

    assign pready_o = 1'b1;
    assign pslverr_o = 1'b0;
    assign irq_o = done_o || error_o;

    always @* begin
        prdata_o = 32'd0;
        case (paddr_i[11:2])
            10'h000: prdata_o = 32'h4c43_4131; // "LCA1"
            10'h001: prdata_o = 32'h0002_0000; // full-chip ABI 2.0
            10'h002: prdata_o = 32'h0000_001f; // verify, decaps, stream, zeroize, ctx
            10'h003: prdata_o = {
                24'd0,
                ingress_error,
                (loaded_mask_o != 6'd0),
                command_pending_o,
                output_active,
                verify_valid_o,
                error_o,
                done_o,
                busy_o
            };
            10'h004: prdata_o = {24'd0, command_reg};
            10'h005: prdata_o = 32'd0; // CONTROL is write-only
            10'h006: prdata_o = message_len_o;
            10'h007: prdata_o = {24'd0, context_len_o};
            10'h008: prdata_o = {26'd0, loaded_mask_o};
            10'h009: prdata_o = {24'd0, result_code_o};
            10'h00a: prdata_o = {16'd0, result_len_q};
            10'h00b: prdata_o = cycle_count_i[31:0];
            10'h00c: prdata_o = cycle_count_i[63:32];
            10'h00d: prdata_o = {24'd0, active_command};
            10'h010: prdata_o = result_words[0];
            10'h011: prdata_o = result_words[1];
            10'h012: prdata_o = result_words[2];
            10'h013: prdata_o = result_words[3];
            10'h014: prdata_o = result_words[4];
            10'h015: prdata_o = result_words[5];
            10'h016: prdata_o = result_words[6];
            10'h017: prdata_o = result_words[7];
            default: prdata_o = 32'd0;
        endcase
    end

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            command_reg      <= CMD_NONE;
            command_o        <= CMD_NONE;
            active_command   <= CMD_NONE;
            command_pending_o <= 1'b0;
            message_len_o    <= 32'd0;
            context_len_o    <= 8'd0;
            loaded_mask_o    <= 6'b001100; // empty message and context are valid
            ingress_error    <= 1'b0;
            busy_o            <= 1'b0;
            done_o            <= 1'b0;
            error_o           <= 1'b0;
            verify_valid_o    <= 1'b0;
            result_code_o     <= RESULT_OK;
            zeroize_req_o     <= 1'b0;
            output_index      <= 3'd0;
            output_bytes_left <= 6'd0;
            output_active     <= 1'b0;
            result_len_q      <= 16'd0;
            for (i = 0; i < 6; i = i + 1)
                byte_count[i] <= 32'd0;
            for (i = 0; i < 8; i = i + 1)
                result_words[i] <= 32'd0;
        end else begin
            zeroize_req_o <= 1'b0;

            if (zeroize_i) begin
                command_reg       <= CMD_NONE;
                command_o         <= CMD_NONE;
                active_command    <= CMD_NONE;
                command_pending_o <= 1'b0;
                message_len_o     <= 32'd0;
                context_len_o     <= 8'd0;
                loaded_mask_o     <= 6'b001100;
                ingress_error     <= 1'b0;
                busy_o             <= 1'b0;
                done_o             <= 1'b0;
                error_o            <= 1'b0;
                verify_valid_o     <= 1'b0;
                result_code_o      <= RESULT_OK;
                output_index       <= 3'd0;
                output_bytes_left  <= 6'd0;
                output_active      <= 1'b0;
                result_len_q       <= 16'd0;
                for (i = 0; i < 6; i = i + 1)
                    byte_count[i] <= 32'd0;
                for (i = 0; i < 8; i = i + 1)
                    result_words[i] <= 32'd0;
            end else begin
                if (stream_fire) begin
                    // A non-empty stream replaces the default empty message
                    // or context marker. Reloading any object requires the
                    // host to clear all buffers first.
                    if (byte_count[s_kind_i] == 0)
                        loaded_mask_o[s_kind_i] <= 1'b0;

                    if (!keep_valid || next_count > stream_limit ||
                        (fixed_length && s_last_i && next_count != stream_limit) ||
                        (fixed_length && !s_last_i && next_count >= stream_limit)) begin
                        ingress_error <= 1'b1;
                        loaded_mask_o[s_kind_i] <= 1'b0;
                    end else begin
                        byte_count[s_kind_i] <= next_count;
                        if (s_last_i) begin
                            loaded_mask_o[s_kind_i] <= 1'b1;
                            if (s_kind_i == STREAM_MESSAGE)
                                message_len_o <= next_count;
                            if (s_kind_i == STREAM_CONTEXT)
                                context_len_o <= next_count[7:0];
                        end
                    end
                end

                if (fw_claim_i)
                    command_pending_o <= 1'b0;

                if (fw_result_we_i)
                    result_words[fw_result_index_i] <= fw_result_data_i;

                if (fw_complete_i && busy_o) begin
                    busy_o          <= 1'b0;
                    done_o          <= 1'b1;
                    result_code_o   <= fw_result_code_i;
                    result_len_q    <= fw_result_len_i;
                    error_o         <= (fw_result_code_i >= 8'h80);
                    verify_valid_o  <= (active_command == CMD_MLDSA65_VERIFY) &&
                                       (fw_result_code_i == RESULT_OK);
                    output_index    <= 3'd0;
                    output_bytes_left <= fw_result_len_i[5:0];
                    output_active   <= (fw_result_len_i != 0) &&
                                       (fw_result_len_i <= 16'd32);
                end

                if (output_active && m_ready_i) begin
                    if (output_bytes_left <= 6'd4) begin
                        output_active <= 1'b0;
                        output_bytes_left <= 6'd0;
                    end else begin
                        output_index <= output_index + 1'b1;
                        output_bytes_left <= output_bytes_left - 6'd4;
                    end
                end

                if (apb_write && pstrb_i[0]) begin
                    case (paddr_i[11:2])
                        10'h004: command_reg <= pwdata_i[7:0];
                        10'h005: begin
                            // bit 0: START
                            if (pwdata_i[0]) begin
                                if (busy_o || command_pending_o) begin
                                    done_o        <= 1'b1;
                                    error_o       <= 1'b1;
                                    result_code_o <= RESULT_BUSY;
                                end else if (ingress_error) begin
                                    done_o        <= 1'b1;
                                    error_o       <= 1'b1;
                                    result_code_o <= RESULT_INPUT_LENGTH;
                                end else if ((command_reg == CMD_MLDSA65_VERIFY &&
                                              ((loaded_mask_o & 6'b001111) != 6'b001111)) ||
                                             (command_reg == CMD_MLKEM768_DECAPS &&
                                              ((loaded_mask_o & 6'b110000) != 6'b110000))) begin
                                    done_o        <= 1'b1;
                                    error_o       <= 1'b1;
                                    result_code_o <= RESULT_INPUT_LENGTH;
                                end else if (command_reg == CMD_MLDSA65_VERIFY ||
                                             command_reg == CMD_MLKEM768_DECAPS ||
                                             command_reg == CMD_SELF_TEST) begin
                                    command_o         <= command_reg;
                                    active_command    <= command_reg;
                                    command_pending_o <= 1'b1;
                                    busy_o             <= 1'b1;
                                    done_o             <= 1'b0;
                                    error_o            <= 1'b0;
                                    verify_valid_o     <= 1'b0;
                                    result_code_o      <= RESULT_OK;
                                    result_len_q       <= 16'd0;
                                    output_index       <= 3'd0;
                                    output_bytes_left  <= 6'd0;
                                    output_active      <= 1'b0;
                                    for (i = 0; i < 8; i = i + 1)
                                        result_words[i] <= 32'd0;
                                end else begin
                                    done_o        <= 1'b1;
                                    error_o       <= 1'b1;
                                    result_code_o <= RESULT_BAD_COMMAND;
                                end
                            end

                            // bit 1: acknowledge completion and scrub output.
                            if (pwdata_i[1] && !busy_o) begin
                                done_o            <= 1'b0;
                                error_o           <= 1'b0;
                                verify_valid_o    <= 1'b0;
                                result_code_o     <= RESULT_OK;
                                result_len_q      <= 16'd0;
                                output_active     <= 1'b0;
                                output_bytes_left <= 6'd0;
                                for (i = 0; i < 8; i = i + 1)
                                    result_words[i] <= 32'd0;
                            end

                            // bit 2: clear input metadata before reloading.
                            if (pwdata_i[2] && !busy_o) begin
                                message_len_o  <= 32'd0;
                                context_len_o  <= 8'd0;
                                loaded_mask_o  <= 6'b001100;
                                ingress_error  <= 1'b0;
                                for (i = 0; i < 6; i = i + 1)
                                    byte_count[i] <= 32'd0;
                            end

                            // bit 3: request a complete SRAM scrub and reboot.
                            if (pwdata_i[3])
                                zeroize_req_o <= 1'b1;
                        end
                        default: begin end
                    endcase
                end
            end
        end
    end

endmodule
