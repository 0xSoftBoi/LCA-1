// SPDX-License-Identifier: Apache-2.0
`default_nettype none

// LCA-1 constant-iteration modular multiplier.
//
// Computes (a * b) mod q without a divider or a wide combinational multiplier.
// The add/double schedule always executes WIDTH cycles for valid inputs. Both
// supported LTP fields fit in WIDTH=24:
//   ML-DSA: q = 8_380_417 (FIPS 204)
//   ML-KEM: q = 3_329     (FIPS 203)
module lca_modmul #(
    parameter integer WIDTH = 24
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [WIDTH-1:0]     a,
    input  wire [WIDTH-1:0]     b,
    input  wire [WIDTH-1:0]     modulus,
    output reg  [WIDTH-1:0]     result,
    output reg                  busy,
    output reg                  done,
    output reg                  error
);

    reg [WIDTH-1:0] accumulator;
    reg [WIDTH-1:0] multiplicand;
    reg [WIDTH-1:0] multiplier;
    reg [5:0]       cycle_count;

    reg [WIDTH:0] dbl_sum;
    reg [WIDTH-1:0] acc_next;
    reg [WIDTH-1:0] multiplicand_next;

    // Inputs to add_mod are canonical (< modulus), so their sum is < 2q and
    // at most one subtraction is necessary.
    function [WIDTH-1:0] add_mod;
        input [WIDTH-1:0] x;
        input [WIDTH-1:0] y;
        input [WIDTH-1:0] q;
        reg   [WIDTH:0]   sum;
        begin
            sum = {1'b0, x} + {1'b0, y};
            if (sum >= {1'b0, q})
                add_mod = sum - {1'b0, q};
            else
                add_mod = sum[WIDTH-1:0];
        end
    endfunction

    always @(*) begin
        dbl_sum = {1'b0, multiplicand} + {1'b0, multiplicand};

        if (multiplier[0])
            acc_next = add_mod(accumulator, multiplicand, modulus);
        else
            acc_next = accumulator;

        if (dbl_sum >= {1'b0, modulus})
            multiplicand_next = dbl_sum - {1'b0, modulus};
        else
            multiplicand_next = dbl_sum[WIDTH-1:0];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result       <= {WIDTH{1'b0}};
            busy         <= 1'b0;
            done         <= 1'b0;
            error        <= 1'b0;
            accumulator  <= {WIDTH{1'b0}};
            multiplicand <= {WIDTH{1'b0}};
            multiplier   <= {WIDTH{1'b0}};
            cycle_count  <= 6'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                if ((modulus == {WIDTH{1'b0}}) || (a >= modulus) || (b >= modulus)) begin
                    result <= {WIDTH{1'b0}};
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    error  <= 1'b1;
                end else begin
                    result       <= {WIDTH{1'b0}};
                    busy         <= 1'b1;
                    error        <= 1'b0;
                    accumulator  <= {WIDTH{1'b0}};
                    multiplicand <= a;
                    multiplier   <= b;
                    cycle_count  <= 6'd0;
                end
            end else if (busy) begin
                accumulator  <= acc_next;
                multiplicand <= multiplicand_next;
                multiplier   <= {1'b0, multiplier[WIDTH-1:1]};

                if (cycle_count == WIDTH - 1) begin
                    result      <= acc_next;
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    cycle_count <= 6'd0;
                end else begin
                    cycle_count <= cycle_count + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
