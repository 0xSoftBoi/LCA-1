`default_nettype none

// Tiny Tapeout wrapper for Suwappu LCA-1.
//
// ui_in[7:0]  : byte-wide register data
// uio_in[3:0] : register address
// uio_in[4]   : write enable
// uio[5]      : busy   (output)
// uio[6]      : done   (latched output)
// uio[7]      : error  (latched output)
module tt_um_suwappu_lattice_accel (
    input  wire [7:0] ui_in,
    output reg  [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    reg [23:0] reg_a;
    reg [23:0] reg_b;
    reg [23:0] reg_zeta;
    reg        mode_kem;
    reg [1:0]  op;

    // A start write snapshots the complete command. Host writes after start
    // therefore prepare the next transaction instead of mutating the command
    // crossing into the core.
    reg [23:0] cmd_a;
    reg [23:0] cmd_b;
    reg [23:0] cmd_zeta;
    reg        cmd_mode_kem;
    reg [1:0]  cmd_op;

    reg        start_pending;
    reg        command_active;
    reg        core_start;
    reg        done_latched;
    reg        error_latched;

    wire [23:0] core_out0;
    wire [23:0] core_out1;
    wire        core_busy;
    wire        core_done;
    wire        core_error;

    wire [3:0] addr = uio_in[3:0];
    wire       wr_en = uio_in[4];

    lca_core u_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(core_start),
        .mode_kem(cmd_mode_kem),
        .op(cmd_op),
        .a(cmd_a),
        .b(cmd_b),
        .zeta(cmd_zeta),
        .out0(core_out0),
        .out1(core_out1),
        .busy(core_busy),
        .done(core_done),
        .error(core_error)
    );

    // Chip-level busy spans the full host-visible transaction, including the
    // launch and completion-latch boundary cycles around the arithmetic core.
    assign uio_out = {error_latched, done_latched, command_active, 5'b00000};
    assign uio_oe  = 8'b1110_0000;

    always @(*) begin
        case (addr)
            // Read bit 7 is the presence bit and bits 6:4 are the hardware
            // major version. Write bit 7 remains the start strobe.
            4'h0: uo_out = {1'b1, 3'b001, 1'b0, op, mode_kem};
            4'h1: uo_out = reg_a[7:0];
            4'h2: uo_out = reg_a[15:8];
            4'h3: uo_out = reg_a[23:16];
            4'h4: uo_out = reg_b[7:0];
            4'h5: uo_out = reg_b[15:8];
            4'h6: uo_out = reg_b[23:16];
            4'h7: uo_out = reg_zeta[7:0];
            4'h8: uo_out = reg_zeta[15:8];
            4'h9: uo_out = reg_zeta[23:16];
            4'hA: uo_out = core_out0[7:0];
            4'hB: uo_out = core_out0[15:8];
            4'hC: uo_out = core_out0[23:16];
            4'hD: uo_out = core_out1[7:0];
            4'hE: uo_out = core_out1[15:8];
            4'hF: uo_out = core_out1[23:16];
            default: uo_out = 8'h00;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_a         <= 24'd0;
            reg_b         <= 24'd0;
            reg_zeta      <= 24'd0;
            mode_kem      <= 1'b0;
            op            <= 2'b00;
            cmd_a          <= 24'd0;
            cmd_b          <= 24'd0;
            cmd_zeta       <= 24'd0;
            cmd_mode_kem   <= 1'b0;
            cmd_op         <= 2'b00;
            start_pending <= 1'b0;
            command_active <= 1'b0;
            core_start    <= 1'b0;
            done_latched  <= 1'b0;
            error_latched <= 1'b0;
        end else begin
            core_start <= 1'b0;

            if (core_done) begin
                command_active <= 1'b0;
                done_latched  <= 1'b1;
                // Preserve a host-protocol violation raised while the command
                // was active. The host must discard that result and recover
                // with a fresh accepted start.
                error_latched <= error_latched | core_error;
            end

            if (start_pending && !core_busy) begin
                core_start    <= 1'b1;
                start_pending <= 1'b0;
                done_latched  <= 1'b0;
                error_latched <= 1'b0;
            end

            if (wr_en && ena) begin
                case (addr)
                    4'h0: begin
                        mode_kem <= ui_in[0];
                        op       <= ui_in[2:1];
                        if (ui_in[7]) begin
                            if (!command_active && !start_pending) begin
                                cmd_a          <= reg_a;
                                cmd_b          <= reg_b;
                                cmd_zeta       <= reg_zeta;
                                cmd_mode_kem   <= ui_in[0];
                                cmd_op         <= ui_in[2:1];
                                start_pending <= 1'b1;
                                command_active <= 1'b1;
                                done_latched  <= 1'b0;
                                error_latched <= 1'b0;
                            end else begin
                                // One command at a time: preserve the active
                                // operation and report that this start write
                                // was rejected.
                                error_latched <= 1'b1;
                            end
                        end
                    end
                    4'h1: reg_a[7:0]       <= ui_in;
                    4'h2: reg_a[15:8]      <= ui_in;
                    4'h3: reg_a[23:16]     <= ui_in;
                    4'h4: reg_b[7:0]       <= ui_in;
                    4'h5: reg_b[15:8]      <= ui_in;
                    4'h6: reg_b[23:16]     <= ui_in;
                    4'h7: reg_zeta[7:0]    <= ui_in;
                    4'h8: reg_zeta[15:8]   <= ui_in;
                    4'h9: reg_zeta[23:16]  <= ui_in;
                    default: begin end
                endcase
            end
        end
    end

    // uio_in[7:5] are output-mode pads and are intentionally ignored.
    wire _unused = &{uio_in[7:5], 1'b0};

endmodule

`default_nettype wire
