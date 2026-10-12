// SPDX-License-Identifier: Apache-2.0
//
// 32 KiB Rev-A secure SRAM implemented as four pinned SRAM22 2048x32 banks.
// The interface is an explicit single-outstanding request/response protocol so
// registered macro reads are represented honestly. Zeroization scrubs four
// words per clock (one row in every bank), completing in 2048 clocks.

`default_nettype none

module lca_secure_sram_sram22 (
`ifdef USE_POWER_PINS
    inout wire         vdd,
    inout wire         vss,
`endif
    input  wire         clk_i,
    input  wire         rst_ni,
    input  wire         zeroize_i,
    output wire         zeroize_busy_o,

    input  wire         req_valid_i,
    output wire         req_ready_o,
    input  wire         req_write_i,
    input  wire [12:0]  req_addr_i,
    input  wire [31:0]  req_wdata_i,
    input  wire [3:0]   req_wstrb_i,

    output wire         rsp_valid_o,
    input  wire         rsp_ready_i,
    output wire [31:0]  rsp_rdata_o
);
    reg        rsp_valid_q;
    reg [31:0] rsp_rdata_q;
    reg        read_pending_q;
    reg [1:0]  read_bank_q;
    reg        zeroize_active_q;
    reg        zeroize_seen_q;
    reg [10:0] zeroize_row_q;

    wire req_fire = req_valid_i && req_ready_o;
    assign req_ready_o = !zeroize_active_q && !zeroize_i && !read_pending_q && !rsp_valid_q;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_rdata_o = rsp_rdata_q;
    assign zeroize_busy_o = zeroize_active_q;

    wire [1:0] req_bank = req_addr_i[12:11];
    wire [10:0] req_row = req_addr_i[10:0];

    wire [31:0] bank_rdata [0:3];
    wire [3:0] bank_ce;
    wire [3:0] bank_we;
    wire [3:0] bank_wmask [0:3];
    wire [10:0] bank_addr [0:3];
    wire [31:0] bank_wdata [0:3];

    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : g_bank
            assign bank_ce[b] = zeroize_active_q || (req_fire && req_bank == b[1:0]);
            assign bank_we[b] = zeroize_active_q || (req_fire && req_write_i && req_bank == b[1:0]);
            assign bank_wmask[b] = zeroize_active_q ? 4'hf : req_wstrb_i;
            assign bank_addr[b] = zeroize_active_q ? zeroize_row_q : req_row;
            assign bank_wdata[b] = zeroize_active_q ? 32'd0 : req_wdata_i;

            lca_sram22_2048x32 u_bank (
`ifdef USE_POWER_PINS
                .vdd(vdd), .vss(vss),
`endif
                .clk_i(clk_i), .rst_ni(rst_ni), .ce_i(bank_ce[b]), .we_i(bank_we[b]),
                .wmask_i(bank_wmask[b]), .addr_i(bank_addr[b]),
                .wdata_i(bank_wdata[b]), .rdata_o(bank_rdata[b])
            );
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rsp_valid_q       <= 1'b0;
            rsp_rdata_q       <= 32'd0;
            read_pending_q    <= 1'b0;
            read_bank_q       <= 2'd0;
            zeroize_active_q  <= 1'b0;
            zeroize_seen_q    <= 1'b0;
            zeroize_row_q     <= 11'd0;
        end else begin
            if (!zeroize_i)
                zeroize_seen_q <= 1'b0;

            if (rsp_valid_q && rsp_ready_i)
                rsp_valid_q <= 1'b0;

            if (zeroize_i && !zeroize_seen_q && !zeroize_active_q) begin
                zeroize_seen_q   <= 1'b1;
                zeroize_active_q <= 1'b1;
                zeroize_row_q    <= 11'd0;
                read_pending_q   <= 1'b0;
                rsp_valid_q      <= 1'b0;
                rsp_rdata_q      <= 32'd0;
            end else if (zeroize_active_q) begin
                if (zeroize_row_q == 11'd2047) begin
                    zeroize_active_q <= 1'b0;
                    zeroize_row_q    <= 11'd0;
                end else begin
                    zeroize_row_q <= zeroize_row_q + 1'b1;
                end
            end else begin
                // Macro dout is registered on the read request edge. Consume
                // it one controller cycle later to avoid simulator/order races.
                if (read_pending_q) begin
                    case (read_bank_q)
                        2'd0: rsp_rdata_q <= bank_rdata[0];
                        2'd1: rsp_rdata_q <= bank_rdata[1];
                        2'd2: rsp_rdata_q <= bank_rdata[2];
                        default: rsp_rdata_q <= bank_rdata[3];
                    endcase
                    rsp_valid_q    <= 1'b1;
                    read_pending_q <= 1'b0;
                end

                if (req_fire) begin
                    if (req_write_i) begin
                        rsp_rdata_q <= 32'd0;
                        rsp_valid_q <= 1'b1;
                    end else begin
                        read_bank_q    <= req_bank;
                        read_pending_q <= 1'b1;
                    end
                end
            end
        end
    end
endmodule

`default_nettype wire
