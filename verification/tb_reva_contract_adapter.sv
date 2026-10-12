// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_reva_contract_adapter_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg tamper_n_i = 1'b1;
    reg zeroize_req_i = 1'b0;
    reg [31:0] mask_rev_i = 32'hcafef00d;
    reg [15:0] host_d_i = 16'd0;
    wire [15:0] host_d_o;
    wire host_d_oe_o;
    reg [7:0] host_addr_i = 8'd0;
    reg req_valid_i = 1'b0;
    wire req_ready_o;
    reg req_write_i = 1'b0;
    reg req_last_i = 1'b1;
    wire rsp_valid_o;
    reg rsp_ready_i = 1'b1;
    wire rsp_last_o;
    wire irq_o, busy_o, fault_o, zeroize_busy_o, selftest_fail_o;
    integer cycles;
    integer idx;
    reg [15:0] commands [0:6];

    lca_reva_contract_adapter #(.SRAM_WORDS(16)) dut (.*);
    always #5 clk_i = ~clk_i;
    task tick; begin @(posedge clk_i); #1; end endtask

    task write_csr(input [7:0] addr, input [15:0] value);
        begin
            while (!req_ready_o) tick();
            host_addr_i = addr; host_d_i = value; req_write_i = 1'b1; req_valid_i = 1'b1;
            tick(); req_valid_i = 1'b0; req_write_i = 1'b0;
            if (!rsp_valid_o) $fatal(1, "missing write response addr=%02x", addr);
            tick();
        end
    endtask

    task read_csr(input [7:0] addr, input [15:0] expected);
        begin
            while (!req_ready_o) tick();
            host_addr_i = addr; req_write_i = 1'b0; req_valid_i = 1'b1;
            tick(); req_valid_i = 1'b0;
            if (!rsp_valid_o || host_d_o !== expected)
                $fatal(1, "read mismatch addr=%02x expected=%04x got=%04x valid=%0d", addr, expected, host_d_o, rsp_valid_o);
            tick();
        end
    endtask

    initial begin
        commands[0] = 16'h0001;
        commands[1] = 16'h0002;
        commands[2] = 16'h0003;
        commands[3] = 16'h0004;
        commands[4] = 16'h0010;
        commands[5] = 16'h0020;
        commands[6] = 16'h007f;

        repeat (3) tick();
        rst_ni = 1'b1;
        cycles = 0;
        while (!req_ready_o && cycles < 100) begin tick(); cycles = cycles + 1; end
        if (!req_ready_o) $fatal(1, "adapter/core never became ready");

        // Every frozen external command must round-trip through the compact
        // internal encoding without leaking that internal encoding on reads.
        for (idx = 0; idx < 7; idx = idx + 1) begin
            write_csr(8'h06, commands[idx]);
            read_csr(8'h06, commands[idx]);
        end

        // A frozen ML-KEM NTT command followed by START reaches the intended
        // internal command. With no 1024-byte staged vector it must fail with
        // LENGTH, not ILLEGAL_COMMAND.
        write_csr(8'h06, 16'h0001);
        write_csr(8'h07, 16'h0001);
        if (!fault_o) $fatal(1, "START without staged NTT input did not fail");
        read_csr(8'h05, 16'h0004);

        // Frozen CLEAR_DONE bit 2 must acknowledge done/irq/non-tamper error.
        write_csr(8'h07, 16'h0004);
        if (fault_o || irq_o) $fatal(1, "CLEAR_DONE did not acknowledge non-tamper status");
        read_csr(8'h05, 16'h0000);

        // Frozen ZEROIZE_ALL bit 3 maps to the internal scrub request.
        write_csr(8'h07, 16'h0008);
        if (!zeroize_busy_o || req_ready_o) $fatal(1, "ZEROIZE_ALL did not seize the core");
        cycles = 0;
        while (zeroize_busy_o && cycles < 100) begin tick(); cycles = cycles + 1; end
        if (zeroize_busy_o || !req_ready_o) $fatal(1, "ZEROIZE_ALL did not recover");

        // Invalid frozen command must map to a fail-closed illegal command.
        write_csr(8'h06, 16'h1234);
        write_csr(8'h07, 16'h0001);
        read_csr(8'h05, 16'h0002);

        $display("PASS: frozen LCA-LINK command/control ABI round-trip and fail-closed translation");
        $finish;
    end
endmodule
