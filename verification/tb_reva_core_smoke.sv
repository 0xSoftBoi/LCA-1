// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_reva_core_smoke_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg tamper_n_i = 1'b1;
    reg zeroize_req_i = 1'b0;
    reg [31:0] mask_rev_i = 32'h12345678;
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

    lca_reva_core dut (.*);
    always #5 clk_i = ~clk_i;

    task tick; begin @(posedge clk_i); #1; end endtask

    task csr_read(input [7:0] addr, input [15:0] expected);
        begin
            host_addr_i = addr; req_write_i = 1'b0; req_valid_i = 1'b1; req_last_i = 1'b1;
            tick(); req_valid_i = 1'b0;
            if (!rsp_valid_o || host_d_o !== expected) begin
                $display("FAIL CSR read %02x expected %04x got %04x valid=%0d", addr, expected, host_d_o, rsp_valid_o);
                $fatal(1);
            end
            tick();
        end
    endtask

    task csr_write(input [7:0] addr, input [15:0] value);
        begin
            host_addr_i = addr; host_d_i = value; req_write_i = 1'b1; req_valid_i = 1'b1; req_last_i = 1'b1;
            tick(); req_valid_i = 1'b0; req_write_i = 1'b0;
            if (!rsp_valid_o) $fatal(1, "missing CSR write response");
            tick();
        end
    endtask

    initial begin
        repeat (3) tick();
        rst_ni = 1'b1;

        // Mandatory power-on scrub: the host must remain blocked until every
        // secure SRAM word has been overwritten.
        cycles = 0;
        while (!req_ready_o && cycles < 9000) begin tick(); cycles = cycles + 1; end
        if (!req_ready_o) $fatal(1, "power-on scrub never released host");
        if (cycles < 8191) $fatal(1, "power-on scrub completed too early: %0d", cycles);
        csr_read(8'h00, 16'h4131);
        csr_read(8'h01, 16'h4c43);
        csr_read(8'h0d, 16'h5678);
        csr_read(8'h0e, 16'h1234);

        // Backpressure: one outstanding response must block a second request.
        rsp_ready_i = 1'b0;
        host_addr_i = 8'h02; req_valid_i = 1'b1; req_write_i = 1'b0;
        tick(); req_valid_i = 1'b0;
        if (!rsp_valid_o || req_ready_o) $fatal(1, "response backpressure invariant broken");
        repeat (3) begin tick(); if (!rsp_valid_o || req_ready_o) $fatal(1, "response was not held"); end
        rsp_ready_i = 1'b1; tick();

        // Illegal command must fail closed without launching an engine.
        csr_write(8'h06, 16'h00ff);
        csr_write(8'h07, 16'h0001);
        if (!fault_o || busy_o) $fatal(1, "illegal command did not fail closed");
        csr_read(8'h05, 16'h0002);
        csr_write(8'h07, 16'h0020); // clear fault
        if (fault_o) $fatal(1, "fault clear failed after non-tamper error");

        // Explicit zeroize blocks requests for a complete SRAM scrub.
        zeroize_req_i = 1'b1; tick(); zeroize_req_i = 1'b0;
        if (!zeroize_busy_o || req_ready_o) $fatal(1, "external zeroize did not seize the core");
        cycles = 0;
        while (zeroize_busy_o && cycles < 9000) begin tick(); cycles = cycles + 1; end
        if (zeroize_busy_o || !req_ready_o) $fatal(1, "external zeroize did not recover");
        if (cycles < 8191) $fatal(1, "external zeroize completed too early: %0d", cycles);

        // Tamper is fail-closed and sticky across the scrub until explicitly
        // acknowledged after tamper_n returns high.
        tamper_n_i = 1'b0; tick();
        if (!fault_o || !zeroize_busy_o || req_ready_o) $fatal(1, "tamper did not enter fail-closed scrub");
        tamper_n_i = 1'b1;
        cycles = 0;
        while (zeroize_busy_o && cycles < 9000) begin tick(); cycles = cycles + 1; end
        if (!fault_o || !req_ready_o) $fatal(1, "tamper fault did not remain sticky after scrub");
        csr_read(8'h05, 16'h0007);
        csr_write(8'h07, 16'h0020);
        if (fault_o) $fatal(1, "tamper fault clear failed after physical release");

        $display("PASS: Rev-A core power-on scrub, CSR, backpressure, fail-closed command, zeroize, and tamper protocol");
        $finish;
    end
endmodule
