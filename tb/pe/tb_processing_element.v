`timescale 1ns/1ps

module tb_processing_element;

    reg         clk;
    reg         rst_n;
    reg  [1:0]  precision_mode;
    reg         acc_clear;
    reg         acc_enable;
    reg  [15:0] operand_a;
    reg  [15:0] operand_b;

    wire [31:0] accum_out;
    wire [15:0] zero_skip_count;

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

    initial clk = 0;
    always #5 clk = ~clk;

    initial begin
        // Initialize all inputs.
        rst_n         = 0;
        precision_mode = 2'b01;  // INT8 SIMD
        acc_clear     = 0;
        acc_enable    = 0;
        operand_a     = 0;
        operand_b     = 0;

        // --------------------------------------------
        // Test 0: Reset
        // --------------------------------------------
        repeat (2) @(negedge clk);
        #1;

        if (accum_out !== 32'h00000000)
            $fatal(1, "Reset failed: accum_out=%h", accum_out);

        if (zero_skip_count !== 16'h0000)
            $fatal(1, "Reset failed: zero_skip_count=%h",
                   zero_skip_count);

        rst_n = 1;
        $display("PASS: reset");

        // --------------------------------------------
        // Test 1: First INT8 accumulation
        // Lane 0: 10*3 = 30
        // Lane 1:  5*2 = 10
        // --------------------------------------------
        @(negedge clk);
        acc_enable = 1;
        operand_a = {8'd5, 8'd10};
        operand_b = {8'd2, 8'd3};

        @(posedge clk);
        #1;

        if (accum_out !== 32'h000A001E)
            $fatal(1, "INT8 test 1 failed: got %h", accum_out);

        $display("PASS: INT8 accumulation test 1");

        // --------------------------------------------
        // Test 2: Accumulate a second product
        // Lane 0: 30 + 4*5 = 50
        // Lane 1: 10 + 3*2 = 16
        // --------------------------------------------
        @(negedge clk);
        operand_a = {8'd3, 8'd4};
        operand_b = {8'd2, 8'd5};

        @(posedge clk);
        #1;

        if (accum_out !== 32'h00100032)
            $fatal(1, "INT8 test 2 failed: got %h", accum_out);

        $display("PASS: INT8 accumulation test 2");

        // --------------------------------------------
        // Test 3: Zero-operand bypass
        // Accumulator should hold its previous value.
        // Counter should increment once.
        // --------------------------------------------
        @(negedge clk);
        operand_a = 16'h0000;
        operand_b = 16'h1234;

        @(posedge clk);
        #1;

        if (accum_out !== 32'h00100032)
            $fatal(1, "Zero bypass failed: accum_out=%h",
                   accum_out);

        if (zero_skip_count !== 16'd1)
            $fatal(1, "Zero skip count failed: got %0d, expected 1",
                   zero_skip_count);

        $display("PASS: zero-operand bypass and counter");

        // --------------------------------------------
        // Test 4: Accumulator clear
        // Clear should reset the accumulator but preserve
        // the zero-skip counter.
        // --------------------------------------------
        @(negedge clk);
        acc_clear = 1;

        @(posedge clk);
        #1;

        if (accum_out !== 32'h00000000)
            $fatal(1, "Accumulator clear failed: got %h",
                   accum_out);

        if (zero_skip_count !== 16'd1)
            $fatal(1, "Counter changed during clear: got %0d",
                   zero_skip_count);

        $display("PASS: accumulator clear");

        @(negedge clk);
        acc_clear = 0;

        // --------------------------------------------
        // Test 5: Signed INT8 products
        // Lane 0: -3 * 4 = -12
        // Lane 1:  5 * -2 = -10
        // Expected packed result: FFF6FFF4
        // --------------------------------------------
        @(negedge clk);
        operand_a = {8'd5, -8'sd3};
        operand_b = {-8'sd2, 8'd4};

        @(posedge clk);
        #1;

        if (accum_out !== 32'hFFF6FFF4)
            $fatal(1, "Signed INT8 test failed: got %h, expected FFF6FFF4",
                   accum_out);

        $display("PASS: signed INT8 products");

        // --------------------------------------------
        // Test 6: Reset while counter is nonzero
        // Asynchronous reset should clear both registers.
        // --------------------------------------------
        @(negedge clk);
        acc_enable = 0;
        rst_n = 0;
        #1;

        if (accum_out !== 32'h00000000)
            $fatal(1, "Reset did not clear accumulator");

        if (zero_skip_count !== 16'h0000)
            $fatal(1, "Reset did not clear zero_skip_count");

        $display("PASS: reset clears accumulator and counter");
        $display("DAY 2 PE TESTS PASSED");
        $finish;
    end

endmodule