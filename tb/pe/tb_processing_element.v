`timescale 1ns/1ps

module tb_processing_element;

    reg        clk;
    reg        rst_n;
    reg [1:0]  precision_mode;
    reg        acc_clear;
    reg        acc_enable;
    reg [15:0] operand_a;
    reg [15:0] operand_b;

    wire [31:0] accum_out;
    wire [15:0] zero_skip_count;

    // Instantiate DUT
    processing_element dut (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .acc_clear(acc_clear),
        .acc_enable(acc_enable),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .accum_out(accum_out),
        .zero_skip_count(zero_skip_count)
    );

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    initial begin
        clk            = 0;
        rst_n          = 0;
        precision_mode = 2'b01; // Default INT8 Mode
        acc_clear      = 0;
        acc_enable     = 0;
        operand_a      = 16'h0000;
        operand_b      = 16'h0000;

        #15 rst_n = 1;
        #10;

        // --- Test 1: INT8 Accumulation ---
        acc_enable = 1;
        operand_a  = {8'sd5, 8'sd10};
        operand_b  = {8'sd2, 8'sd3};
        #10; // Accumulates: lane1 = 10, lane0 = 30

        operand_a  = {8'sd3, 8'sd4};
        operand_b  = {8'sd2, 8'sd5};
        #10; // Accumulates: lane1 += 6 (16), lane0 += 20 (50)

        // --- Test 2: Zero-Bypass Trigger ---
        operand_a  = 16'h0000; // Activation is zero!
        operand_b  = {8'sd10, 8'sd10};
        #10; // accum_out should freeze, zero_skip_count should increment to 1

        // --- Test 3: Clear Accumulator ---
        acc_clear = 1;
        #10;
        acc_clear = 0;
        #10;

        $display("DAY 2 VERIFICATION COMPLETE! zero_skips = %d, accum_out = %h", zero_skip_count, accum_out);
        $finish;
    end

endmodule