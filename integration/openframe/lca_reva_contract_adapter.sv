// SPDX-License-Identifier: Apache-2.0
//
// External LCA-LINK-16 contract adapter for the bounded Rev-A core.
//
// lca_reva_core predates the frozen fabrication manifest and uses compact
// internal command/control encodings. This adapter is the only OpenFrame-facing
// ABI boundary: it translates the frozen external values into the internal
// values without changing data-channel addresses or response semantics.

`default_nettype none

module lca_reva_contract_adapter #(
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
    localparam [7:0] CSR_COMMAND = 8'h06;
    localparam [7:0] CSR_CONTROL = 8'h07;

    // Frozen external command values from fabrication/rev_a_release.json.
    localparam [15:0] EXT_MLKEM_NTT    = 16'h0001;
    localparam [15:0] EXT_MLKEM_INTT   = 16'h0002;
    localparam [15:0] EXT_MLDSA_NTT    = 16'h0003;
    localparam [15:0] EXT_MLDSA_INTT   = 16'h0004;
    localparam [15:0] EXT_KECCAK       = 16'h0010;
    localparam [15:0] EXT_MOD_ARITH    = 16'h0020;
    localparam [15:0] EXT_SELF_TEST    = 16'h007f;

    reg [15:0] translated_data;
    wire [15:0] core_host_d_o;
    wire        core_rsp_valid;
    reg         command_read_pending_q;

    function automatic [15:0] internal_command_to_external;
        input [15:0] value;
        begin
            case (value[7:0])
                8'h00: internal_command_to_external = EXT_MLKEM_NTT;
                8'h01: internal_command_to_external = EXT_MLKEM_INTT;
                8'h02: internal_command_to_external = EXT_MLDSA_NTT;
                8'h03: internal_command_to_external = EXT_MLDSA_INTT;
                8'h04: internal_command_to_external = EXT_KECCAK;
                8'h05: internal_command_to_external = EXT_MOD_ARITH;
                8'h07: internal_command_to_external = EXT_SELF_TEST;
                default: internal_command_to_external = 16'hffff;
            endcase
        end
    endfunction

    always @* begin
        translated_data = host_d_i;
        if (req_write_i && host_addr_i == CSR_COMMAND) begin
            case (host_d_i)
                EXT_MLKEM_NTT:  translated_data = 16'h0000;
                EXT_MLKEM_INTT: translated_data = 16'h0001;
                EXT_MLDSA_NTT:  translated_data = 16'h0002;
                EXT_MLDSA_INTT: translated_data = 16'h0003;
                EXT_KECCAK:     translated_data = 16'h0004;
                EXT_MOD_ARITH:  translated_data = 16'h0005;
                EXT_SELF_TEST:  translated_data = 16'h0007;
                default:        translated_data = 16'h00ff; // fail closed in core
            endcase
        end else if (req_write_i && host_addr_i == CSR_CONTROL) begin
            // External frozen bits:
            //   0 START
            //   1 ABORT
            //   2 CLEAR_DONE (also acknowledge irq/non-tamper fault)
            //   3 ZEROIZE_ALL
            //   4 RESET_STREAM_CURSORS
            // Internal legacy bits:
            //   0 START, 1 ABORT, 2 ZEROIZE, 3 CLEAR_DONE,
            //   4 CLEAR_IRQ, 5 CLEAR_FAULT, 6 RESET_STREAM_CURSORS.
            translated_data = 16'd0;
            translated_data[0] = host_d_i[0];
            translated_data[1] = host_d_i[1];
            translated_data[2] = host_d_i[3];
            translated_data[3] = host_d_i[2];
            translated_data[4] = host_d_i[2];
            translated_data[5] = host_d_i[2];
            translated_data[6] = host_d_i[4];
        end
    end

    // The core has one outstanding response maximum, so a single bit is enough
    // to remember whether the accepted read requires command readback mapping.
    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            command_read_pending_q <= 1'b0;
        end else begin
            if (req_valid_i && req_ready_o && !req_write_i && host_addr_i == CSR_COMMAND)
                command_read_pending_q <= 1'b1;
            if (core_rsp_valid && rsp_ready_i)
                command_read_pending_q <= 1'b0;
        end
    end

    assign host_d_o = command_read_pending_q ?
                      internal_command_to_external(core_host_d_o) : core_host_d_o;
    assign rsp_valid_o = core_rsp_valid;

    lca_reva_core #(.SRAM_WORDS(SRAM_WORDS)) u_core (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .tamper_n_i(tamper_n_i),
        .zeroize_req_i(zeroize_req_i),
        .mask_rev_i(mask_rev_i),
        .host_d_i(translated_data),
        .host_d_o(core_host_d_o),
        .host_d_oe_o(host_d_oe_o),
        .host_addr_i(host_addr_i),
        .req_valid_i(req_valid_i),
        .req_ready_o(req_ready_o),
        .req_write_i(req_write_i),
        .req_last_i(req_last_i),
        .rsp_valid_o(core_rsp_valid),
        .rsp_ready_i(rsp_ready_i),
        .rsp_last_o(rsp_last_o),
        .irq_o(irq_o),
        .busy_o(busy_o),
        .fault_o(fault_o),
        .zeroize_busy_o(zeroize_busy_o),
        .selftest_fail_o(selftest_fail_o)
    );
endmodule

`default_nettype wire
