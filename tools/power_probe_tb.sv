// SPDX-License-Identifier: Apache-2.0
//
// Standalone activity-probe bench for `rtl/lca_modmul.sv`.
//
// This bench exists only to produce a VCD for `tools/power_trace_from_vcd.py`.
// It is deliberately separate from `verification/tb_lca_butterfly.sv`, which is
// the functional regression and must stay free of dump instrumentation.
//
// One simulation runs exactly one modular multiply so that every emitted trace
// covers one operation with identical cycle alignment:
//
//   3 reset cycles -> 1 idle cycle -> request accepted -> 24 constant
//   iterations -> response accepted -> 3 idle cycles -> $finish.
//
// Plusargs:
//   +a=<decimal>     multiplicand, must be < q
//   +b=<decimal>     multiplier, must be < q
//   +q=<decimal>     modulus (3329 for ML-KEM, 8380417 for ML-DSA)
//   +vcd=<path>      VCD output path
//
// The bench prints `PRODUCT <value>` so a caller can check the arithmetic; it
// makes no power claim of any kind.

`timescale 1ns/1ps
`default_nettype none

module power_probe_tb;
    localparam int WORD_BITS = 24;
    localparam int IDLE_TAIL_CYCLES = 3;

    logic                 clk = 1'b0;
    logic                 rst_n = 1'b0;
    logic                 req_valid = 1'b0;
    logic                 req_ready;
    logic [WORD_BITS-1:0] req_a = '0;
    logic [WORD_BITS-1:0] req_b = '0;
    logic [WORD_BITS-1:0] req_modulus = '0;
    logic                 rsp_valid;
    logic                 rsp_ready = 1'b0;
    logic [WORD_BITS-1:0] rsp_product;

    integer stim_a = 0;
    integer stim_b = 0;
    integer stim_q = 3329;
    string  vcd_path = "power_probe.vcd";
    integer guard = 0;

    always #5 clk = ~clk;

    lca_modmul #(.WORD_BITS(WORD_BITS)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_valid   (req_valid),
        .req_ready   (req_ready),
        .req_a       (req_a),
        .req_b       (req_b),
        .req_modulus (req_modulus),
        .rsp_valid   (rsp_valid),
        .rsp_ready   (rsp_ready),
        .rsp_product (rsp_product)
    );

    initial begin
        void'($value$plusargs("a=%d", stim_a));
        void'($value$plusargs("b=%d", stim_b));
        void'($value$plusargs("q=%d", stim_q));
        void'($value$plusargs("vcd=%s", vcd_path));

        if (stim_q <= 0)
            $fatal(1, "modulus must be positive");
        if (stim_a < 0 || stim_a >= stim_q || stim_b < 0 || stim_b >= stim_q)
            $fatal(1, "operands must lie in [0, q)");

        $dumpfile(vcd_path);
        $dumpvars(0, power_probe_tb);

        req_a       = stim_a[WORD_BITS-1:0];
        req_b       = stim_b[WORD_BITS-1:0];
        req_modulus = stim_q[WORD_BITS-1:0];

        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        guard = 0;
        while (!req_ready && guard < 64) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (!req_ready)
            $fatal(1, "multiplier never became ready");

        req_valid = 1'b1;
        @(negedge clk);
        req_valid = 1'b0;

        guard = 0;
        while (!rsp_valid && guard < 64) begin
            @(negedge clk);
            guard = guard + 1;
        end
        if (!rsp_valid)
            $fatal(1, "response timeout");

        $display("PRODUCT %0d", rsp_product);

        rsp_ready = 1'b1;
        @(negedge clk);
        rsp_ready = 1'b0;

        repeat (IDLE_TAIL_CYCLES) @(negedge clk);
        $finish;
    end
endmodule

`default_nettype wire
