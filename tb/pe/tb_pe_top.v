`timescale 1ns/1ps

module tb_pe_top;

    reg        clk;
    reg        rst_n;
    reg [1:0]  precision_mode;
    reg        acc_clear;
    reg        acc_enable;
    reg [15:0] operand_a;
    reg [15:0] operand_b;
    reg [31:0] scale_m0;
    reg [4:0]  shift_n;
    reg [7:0]  zero_point_z;

    wire [15:0] pe_data_out;
    wire [15:0] zero_skip_count;

    // Instantiate Top-Level Integrated PE Module
    pe_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .acc_clear(acc_clear),
        .acc_enable(acc_enable),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .pe_data_out(pe_data_out),
        .zero_skip_count(zero_skip_count)
    );

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    initial begin
        clk            = 0;
        rst_n          = 0;
        precision_mode = 2'b01; // INT8 Mode
        acc_clear      = 0;
        acc_enable     = 0;
        operand_a      = 16'h0000;
        operand_b      = 16'h0000;

        // Post-Processing Scale Configuration (Scale down by 0.5)
        scale_m0       = 32'sd1073741824; // M_0 = 0.5 in Q31
        shift_n        = 5'd31;
        zero_point_z   = 8'sd0;

        #15 rst_n = 1;
        #10;

        // --- Step 1: Accumulate MAC operations ---
        acc_enable = 1;
        operand_a  = {8'sd10, 8'sd20};
        operand_b  = {8'sd2,  8'sd2};
        #10; // Partial sum: lane1 = 20, lane0 = 40

        operand_a  = {8'sd10, 8'sd10};
        operand_b  = {8'sd3,  8'sd1};
        #10; // Partial sum: lane1 = 20 + 30 = 50, lane0 = 40 + 10 = 50

        // --- Step 2: Trigger Zero-Bypass Sparsity ---
        operand_a  = 16'h0000;
        operand_b  = {8'sd5, 8'sd5};
        #10; // Zero-bypass active, zero_skip_count increments

        acc_enable = 0;
        #10; // Wait 1 cycle for pipeline register output latch

        $display("DAY 4 INTEGRATION COMPLETE!");
        $display("Final Scaled Output = %h (Decimal: %d), Zero Skips = %d", 
                 pe_data_out, $signed(pe_data_out[7:0]), zero_skip_count);

        $finish;
    end

endmodule