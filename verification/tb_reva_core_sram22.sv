// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module lca_reva_core_sram22_tb;
    reg clk_i = 1'b0;
    reg rst_ni = 1'b0;
    reg tamper_n_i = 1'b1;
    reg zeroize_req_i = 1'b0;
    reg [31:0] mask_rev_i = 32'h13579bdf;
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

    lca_reva_core_sram22 dut (.*);

    always #5 clk_i = ~clk_i;
    task tick; begin @(posedge clk_i); #1; end endtask

    task wait_ready;
        begin
            cycles = 0;
            while (!req_ready_o && cycles < 5000) begin
                tick();
                cycles = cycles + 1;
            end
            if (!req_ready_o) $fatal(1, "core never became ready");
        end
    endtask

    task write_req(input [7:0] addr, input [15:0] data, input last);
        begin
            wait_ready();
            host_addr_i = addr;
            host_d_i = data;
            req_write_i = 1'b1;
            req_last_i = last;
            req_valid_i = 1'b1;
            tick();
            req_valid_i = 1'b0;
            req_write_i = 1'b0;
            req_last_i = 1'b1;
            cycles = 0;
            while (!rsp_valid_o && cycles < 20) begin tick(); cycles = cycles + 1; end
            if (!rsp_valid_o) $fatal(1, "missing write response addr=%02x", addr);
            tick();
        end
    endtask

    task read_req(input [7:0] addr, input last, input [15:0] expected);
        begin
            wait_ready();
            host_addr_i = addr;
            req_write_i = 1'b0;
            req_last_i = last;
            req_valid_i = 1'b1;
            tick();
            req_valid_i = 1'b0;
            req_last_i = 1'b1;
            cycles = 0;
            while (!rsp_valid_o && cycles < 20) begin tick(); cycles = cycles + 1; end
            if (!rsp_valid_o || host_d_o !== expected)
                $fatal(1, "read mismatch addr=%02x expected=%04x got=%04x valid=%0d", addr, expected, host_d_o, rsp_valid_o);
            tick();
        end
    endtask

    initial begin
        repeat (3) tick();
        rst_ni = 1'b1;

        // Power-on must scrub all four secure SRAM banks and both NTT banks.
        wait_ready();
        if (cycles < 2047) $fatal(1, "power-on scrub completed too early: %0d", cycles);
        read_req(8'h00, 1'b1, 16'h4131);
        read_req(8'h01, 1'b1, 16'h4c43);
        read_req(8'h02, 1'b1, 16'h0001);
        read_req(8'h0d, 1'b1, 16'h9bdf);
        read_req(8'h0e, 1'b1, 16'h1357);

        // Frozen command ABI is native in the physical core.
        write_req(8'h06, 16'h0001, 1'b1);
        read_req(8'h06, 1'b1, 16'h0001);
        write_req(8'h07, 16'h0001, 1'b1); // START with no staged NTT vector
        if (!fault_o) $fatal(1, "unstaged NTT START did not fail closed");
        read_req(8'h05, 1'b1, 16'h0004); // LENGTH
        write_req(8'h07, 16'h0004, 1'b1); // CLEAR_DONE/irq/non-tamper error
        if (fault_o || irq_o) $fatal(1, "CLEAR_DONE did not acknowledge status");

        // Registered secure SRAM write/read path through LCA-LINK.
        write_req(8'h88, 16'hbeef, 1'b1);
        read_req(8'h8a, 1'b1, 16'hbeef);

        // External zeroize must seize the interface and return SRAM contents to zero.
        zeroize_req_i = 1'b1;
        tick();
        zeroize_req_i = 1'b0;
        if (!zeroize_busy_o || req_ready_o) $fatal(1, "external zeroize did not seize core");
        wait_ready();
        read_req(8'h8a, 1'b1, 16'h0000);

        // Built-in self-test exercises the physical NTT + Keccak path.
        write_req(8'h06, 16'h007f, 1'b1);
        write_req(8'h07, 16'h0001, 1'b1);
        cycles = 0;
        while (!irq_o && cycles < 5000) begin tick(); cycles = cycles + 1; end
        if (!irq_o) $fatal(1, "self-test timed out");
        if (selftest_fail_o || fault_o) $fatal(1, "physical self-test failed");
        write_req(8'h07, 16'h0004, 1'b1);

        // Tamper is fail closed and sticky until acknowledged after release.
        tamper_n_i = 1'b0;
        tick();
        if (!zeroize_busy_o || !fault_o || req_ready_o) $fatal(1, "tamper did not trigger fail-closed scrub");
        tamper_n_i = 1'b1;
        wait_ready();
        read_req(8'h05, 1'b1, 16'h0008);
        write_req(8'h07, 16'h0004, 1'b1);
        if (fault_o) $fatal(1, "tamper fault did not clear after physical release");

        $display("PASS: physical Rev-A core boot scrub, frozen ABI, registered SRAM, zeroize, self-test, and tamper");
        $finish;
    end
endmodule
