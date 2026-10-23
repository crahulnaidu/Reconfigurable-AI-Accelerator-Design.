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

    // 100 MHz clock
initial clk = 0;
always #5 clk = ~clk;

initial begin
    rst_n          = 0;
    precision_mode = 2'b01;
    acc_clear      = 0;
    acc_enable     = 0;
    operand_a      = 16'h0000;
    operand_b      = 16'h0000;

    // Hold reset across clock edges.
    repeat (2) @(negedge clk);
    rst_n = 1;

    // ---------------------------------------
    // Test 1: First INT8 accumulation
    // ---------------------------------------
    @(negedge clk);
    acc_enable = 1;
    operand_a  = {8'd5, 8'd10};
    operand_b  = {8'd2, 8'd3};

    // Wait until the accumulator has sampled the operands.
    @(posedge clk);
    #1;

    if (accum_out !== 32'h000A001E)
        $fatal(1,
            "INT8 test 1 failed: got %h, expected 000A001E",
            accum_out);
    else
        $display("PASS: INT8 accumulation test 1");

    // ---------------------------------------
    // Test 2: Second INT8 accumulation
    // ---------------------------------------
    @(negedge clk);
    operand_a = {8'd3, 8'd4};
    operand_b = {8'd2, 8'd5};

    @(posedge clk);
    #1;

    if (accum_out !== 32'h00100032)
        $fatal(1,
            "INT8 test 2 failed: got %h, expected 00100032",
            accum_out);
    else
        $display("PASS: INT8 accumulation test 2");

    // Stop accumulation before the next operation.
    @(negedge clk);
    acc_enable = 0;

    $display("INT8 arithmetic checks passed.");
    $finish;
end
endmodule