// SPDX-FileCopyrightText: 2020 Efabless Corporation
// SPDX-FileCopyrightText: 2026 LCA-1 contributors
// SPDX-License-Identifier: Apache-2.0
//
// LCA-1 Rev-A drop-in replacement for the wrapper in the pinned ChipFoundry
// OpenFrame template. The module signature intentionally matches commit
// ca732a645568d89efc9db3052eadeca47c60cf4d exactly at the shell boundary.

`default_nettype none

module openframe_project_wrapper (
`ifdef USE_POWER_PINS
    inout vdda,
    inout vdda1,
    inout vdda2,
    inout vssa,
    inout vssa1,
    inout vssa2,
    inout vccd,
    inout vccd1,
    inout vccd2,
    inout vssd,
    inout vssd1,
    inout vssd2,
    inout vddio,
    inout vssio,
`endif
    input        porb_h,
    input        porb_l,
    input        por_l,
    input        resetb_h,
    input        resetb_l,
    input [31:0] mask_rev,

    input  [`OPENFRAME_IO_PADS-1:0] gpio_in,
    input  [`OPENFRAME_IO_PADS-1:0] gpio_in_h,
    output [`OPENFRAME_IO_PADS-1:0] gpio_out,
    output [`OPENFRAME_IO_PADS-1:0] gpio_oeb,
    output [`OPENFRAME_IO_PADS-1:0] gpio_inp_dis,
    output [`OPENFRAME_IO_PADS-1:0] gpio_ib_mode_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_vtrip_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_slow_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_holdover,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_en,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_sel,
    output [`OPENFRAME_IO_PADS-1:0] gpio_analog_pol,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm2,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm1,
    output [`OPENFRAME_IO_PADS-1:0] gpio_dm0,

    inout  [`OPENFRAME_IO_PADS-1:0] analog_io,
    inout  [`OPENFRAME_IO_PADS-1:0] analog_noesd_io,

    input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_one,
    input  [`OPENFRAME_IO_PADS-1:0] gpio_loopback_zero
);

    wire host_clk = gpio_in[38];
    wire reset_async_n = porb_l & resetb_l;

    // Fabrication contract: asynchronous assertion, two-flop synchronized
    // deassertion into the sole functional clock domain.
    reg reset_sync_meta_q;
    reg reset_sync_q;
    always @(posedge host_clk or negedge reset_async_n) begin
        if (!reset_async_n) begin
            reset_sync_meta_q <= 1'b0;
            reset_sync_q <= 1'b0;
        end else begin
            reset_sync_meta_q <= 1'b1;
            reset_sync_q <= reset_sync_meta_q;
        end
    end
    wire core_rst_ni = reset_sync_q;

    wire [15:0] host_d_out;
    wire        host_d_oe;
    wire        req_ready;
    wire        rsp_valid;
    wire        rsp_last;
    wire        irq;
    wire        busy;
    wire        fault;
    wire        zeroize_busy;
    wire        selftest_fail;

    reg [`OPENFRAME_IO_PADS-1:0] gpio_out_q;
    reg [`OPENFRAME_IO_PADS-1:0] gpio_oeb_q;
    reg [`OPENFRAME_IO_PADS-1:0] gpio_inp_dis_q;
    reg [`OPENFRAME_IO_PADS-1:0] gpio_dm2_q;
    reg [`OPENFRAME_IO_PADS-1:0] gpio_dm1_q;
    reg [`OPENFRAME_IO_PADS-1:0] gpio_dm0_q;

    // All OpenFrame traffic enters through the frozen external ABI adapter;
    // the bounded core's older compact encoding is not visible at the pins.
    lca_reva_contract_adapter u_lca_reva_core (
        .clk_i(host_clk),
        .rst_ni(core_rst_ni),
        .tamper_n_i(gpio_in[32]),
        .zeroize_req_i(gpio_in[33]),
        .mask_rev_i(mask_rev),
        .host_d_i(gpio_in[15:0]),
        .host_d_o(host_d_out),
        .host_d_oe_o(host_d_oe),
        .host_addr_i(gpio_in[23:16]),
        .req_valid_i(gpio_in[24]),
        .req_ready_o(req_ready),
        .req_write_i(gpio_in[26]),
        .req_last_i(gpio_in[27]),
        .rsp_valid_o(rsp_valid),
        .rsp_ready_i(gpio_in[29]),
        .rsp_last_o(rsp_last),
        .irq_o(irq),
        .busy_o(busy),
        .fault_o(fault),
        .zeroize_busy_o(zeroize_busy),
        .selftest_fail_o(selftest_fail)
    );

    always @* begin
        gpio_out_q = {`OPENFRAME_IO_PADS{1'b0}};
        gpio_out_q[15:0] = host_d_out;
        gpio_out_q[25] = req_ready;
        gpio_out_q[28] = rsp_valid;
        gpio_out_q[30] = rsp_last;
        gpio_out_q[31] = irq;
        gpio_out_q[34] = busy;
        gpio_out_q[35] = fault;
        gpio_out_q[36] = zeroize_busy;
        gpio_out_q[37] = selftest_fail;

        // Output-enable is active low. All pins default to input/Hi-Z. The
        // bidirectional host data bus drives only while a response is pending.
        gpio_oeb_q = {`OPENFRAME_IO_PADS{1'b1}};
        gpio_oeb_q[15:0] = {16{~host_d_oe}};
        gpio_oeb_q[25] = 1'b0;
        gpio_oeb_q[28] = 1'b0;
        gpio_oeb_q[30] = 1'b0;
        gpio_oeb_q[31] = 1'b0;
        gpio_oeb_q[34] = 1'b0;
        gpio_oeb_q[35] = 1'b0;
        gpio_oeb_q[36] = 1'b0;
        gpio_oeb_q[37] = 1'b0;

        // Inputs remain enabled for host_d and all input-only pins. Disable
        // digital input buffers only on driven status outputs and reserved IO.
        gpio_inp_dis_q = {`OPENFRAME_IO_PADS{1'b0}};
        gpio_inp_dis_q[25] = 1'b1;
        gpio_inp_dis_q[28] = 1'b1;
        gpio_inp_dis_q[30] = 1'b1;
        gpio_inp_dis_q[31] = 1'b1;
        gpio_inp_dis_q[34] = 1'b1;
        gpio_inp_dis_q[35] = 1'b1;
        gpio_inp_dis_q[36] = 1'b1;
        gpio_inp_dis_q[37] = 1'b1;
        gpio_inp_dis_q[43:39] = 5'b11111;

        // Default input pad drive mode is 001. Bidirectional host data and
        // output-only status pins use 110. Reserved pins use disabled 000.
        gpio_dm2_q = {`OPENFRAME_IO_PADS{1'b0}};
        gpio_dm1_q = {`OPENFRAME_IO_PADS{1'b0}};
        gpio_dm0_q = {`OPENFRAME_IO_PADS{1'b1}};
        gpio_dm2_q[15:0] = 16'hffff;
        gpio_dm1_q[15:0] = 16'hffff;
        gpio_dm0_q[15:0] = 16'h0000;
        gpio_dm2_q[25] = 1'b1; gpio_dm1_q[25] = 1'b1; gpio_dm0_q[25] = 1'b0;
        gpio_dm2_q[28] = 1'b1; gpio_dm1_q[28] = 1'b1; gpio_dm0_q[28] = 1'b0;
        gpio_dm2_q[30] = 1'b1; gpio_dm1_q[30] = 1'b1; gpio_dm0_q[30] = 1'b0;
        gpio_dm2_q[31] = 1'b1; gpio_dm1_q[31] = 1'b1; gpio_dm0_q[31] = 1'b0;
        gpio_dm2_q[34] = 1'b1; gpio_dm1_q[34] = 1'b1; gpio_dm0_q[34] = 1'b0;
        gpio_dm2_q[35] = 1'b1; gpio_dm1_q[35] = 1'b1; gpio_dm0_q[35] = 1'b0;
        gpio_dm2_q[36] = 1'b1; gpio_dm1_q[36] = 1'b1; gpio_dm0_q[36] = 1'b0;
        gpio_dm2_q[37] = 1'b1; gpio_dm1_q[37] = 1'b1; gpio_dm0_q[37] = 1'b0;
        gpio_dm0_q[43:39] = 5'b00000;
    end

    assign gpio_out = gpio_out_q;
    assign gpio_oeb = gpio_oeb_q;
    assign gpio_inp_dis = gpio_inp_dis_q;
    assign gpio_dm2 = gpio_dm2_q;
    assign gpio_dm1 = gpio_dm1_q;
    assign gpio_dm0 = gpio_dm0_q;

    assign gpio_ib_mode_sel = gpio_loopback_zero;
    assign gpio_vtrip_sel = gpio_loopback_zero;
    assign gpio_slow_sel = gpio_loopback_one;
    assign gpio_holdover = gpio_loopback_zero;
    assign gpio_analog_en = gpio_loopback_zero;
    assign gpio_analog_sel = gpio_loopback_zero;
    assign gpio_analog_pol = gpio_loopback_zero;

    // Keep the template's explicit user-domain power-net anchors so the
    // OpenFrame integration flow sees the same expected hierarchy.
    (* keep *) vccd1_connection vccd1_connection ();
    (* keep *) vssd1_connection vssd1_connection ();

    // Deliberately unused shell signals are retained in the exact pinned
    // signature for drop-in compatibility.
    wire _unused_ok = &{1'b0, porb_h, por_l, resetb_h, gpio_in_h[0],
                        analog_io[0], analog_noesd_io[0]};

endmodule

`default_nettype wire
