`timescale 1ns/1ps

module tb_pe_multiplier;

    reg  [1:0]  precision_mode;
    reg  [15:0] operand_a;
    reg  [15:0] operand_b;
    wire [31:0] product_out;

    integer tests_run;
    integer failures;

    // Device under test
    pe_multiplier uut (
        .precision_mode(precision_mode),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .product_out(product_out)
    );

    // Compare the actual output against the expected output.
    task check_result;
        input [255:0] test_name;
        input [1:0]   mode;
        input [15:0]  a;
        input [15:0]  b;
        input [31:0]  expected;
        begin
            precision_mode = mode;
            operand_a      = a;
            operand_b      = b;

            #1;

            tests_run = tests_run + 1;

            if (product_out !== expected) begin
                $display(
                    "FAIL: %0s | mode=%b a=%h b=%h expected=%h got=%h",
                    test_name,
                    mode,
                    a,
                    b,
                    expected,
                    product_out
                );
                failures = failures + 1;
            end else begin
                $display(
                    "PASS: %0s | mode=%b a=%h b=%h result=%h",
                    test_name,
                    mode,
                    a,
                    b,
                    product_out
                );
            end
        end
    endtask

    initial begin
        tests_run = 0;
        failures  = 0;

        precision_mode = 2'b00;
        operand_a      = 16'h0000;
        operand_b      = 16'h0000;

        #1;

        $display("========================================");
        $display(" PE MULTIPLIER VERIFICATION");
        $display("========================================");

        // --------------------------------------------------
        // Test 1: INT8 positive products
        //
        // Lane 0: 2 * 3 = 6
        // Lane 1: 4 * 5 = 20
        // Expected: {20, 6}
        // --------------------------------------------------
        check_result(
            "INT8 positive products",
            2'b01,
            16'h0402,
            16'h0503,
            32'h0014_0006
        );

        // --------------------------------------------------
        // Test 2: INT8 signed products
        //
        // Lane 0: -3 * 4  = -12 = FFF4
        // Lane 1:  5 * -2 = -10 = FFF6
        // Expected: {FFF6, FFF4}
        // --------------------------------------------------
        check_result(
            "INT8 signed products",
            2'b01,
            16'h05FD,
            16'hFE04,
            32'hFFF6_FFF4
        );

        // --------------------------------------------------
        // Test 3: INT8 boundary values
        //
        // Lane 0: -128 * 1  = -128 = FF80
        // Lane 1:  127 * -1 = -127 = FF81
        // Expected: {FF81, FF80}
        // --------------------------------------------------
        check_result(
            "INT8 boundary products",
            2'b01,
            16'h7F80,
            16'hFF01,
            32'hFF81_FF80
        );

        // --------------------------------------------------
        // Test 4: INT4 mixed signed products
        //
        // Lane 0:  2 *  3  =  6 = 06
        // Lane 1: -1 * -1  =  1 = 01
        // Lane 2: -8 * -1  =  8 = 08
        // Lane 3:  7 *  2  = 14 = 0E
        // Expected: {0E, 08, 01, 06}
        // --------------------------------------------------
        check_result(
            "INT4 mixed signed products",
            2'b10,
            16'h78F2,
            16'h2FF3,
            32'h0E08_0106
        );

        // --------------------------------------------------
        // Test 5: INT4 boundary values
        //
        // Lane 0:  0 * -8 =   0 = 00
        // Lane 1: -8 *  1 =  -8 = F8
        // Lane 2: -1 *  7 =  -7 = F9
        // Lane 3:  7 *  7 =  49 = 31
        // Expected: {31, F9, F8, 00}
        // --------------------------------------------------
        check_result(
            "INT4 boundary products",
            2'b10,
            16'h7F80,
            16'h7718,
            32'h31F9_F800
        );

        // --------------------------------------------------
        // Test 6: Unsupported precision mode
        // Expected output: zero
        // --------------------------------------------------
        check_result(
            "Unsupported mode",
            2'b11,
            16'h1234,
            16'h5678,
            32'h0000_0000
        );

        // --------------------------------------------------
        // Test 7: FP16 1.0 * 1.0
        //
        // 1.0 in IEEE-754 FP16 = 16'h3C00
        // Expected result = 16'h3C00
        //
        // Note: The current RTL may fail because its
        // mantissa extraction is not correctly normalized.
        // --------------------------------------------------
        check_result(
            "FP16 one times one",
            2'b00,
            16'h3C00,
            16'h3C00,
            32'h0000_3C00
        );

        // --------------------------------------------------
        // Test 8: FP16 1.5 * 2.0
        //
        // 1.5 in IEEE-754 FP16 = 16'h3E00
        // 2.0 in IEEE-754 FP16 = 16'h4000
        // Expected result = 3.0 = 16'h4200
        //
        // Note: The current RTL may fail because its
        // mantissa extraction is not correctly normalized.
        // --------------------------------------------------
        check_result(
            "FP16 one-point-five times two",
            2'b00,
            16'h3E00,
            16'h4000,
            32'h0000_4200
        );

                // Test 9: FP16 negative one times positive one
        // -1.0 * 1.0 = -1.0
        check_result(
            "FP16 negative one times one",
            2'b00,
            16'hBC00,
            16'h3C00,
            32'h0000_BC00
        );

        // Test 10: FP16 0.5 times 0.5
        // 0.5 * 0.5 = 0.25
        check_result(
            "FP16 half times half",
            2'b00,
            16'h3800,
            16'h3800,
            32'h0000_3400
        );

        // Test 11: FP16 2.0 times 2.0
        // 2.0 * 2.0 = 4.0
        check_result(
            "FP16 two times two",
            2'b00,
            16'h4000,
            16'h4000,
            32'h0000_4400
        );

        // Test 12: FP16 zero times one
        // Expected IEEE-754 result = positive zero
        check_result(
            "FP16 zero times one",
            2'b00,
            16'h0000,
            16'h3C00,
            32'h0000_0000
        );

        // --------------------------------------------------
        // Final summary
        // --------------------------------------------------
        $display("");
        $display("========================================");
        $display(" MULTIPLIER VERIFICATION SUMMARY");
        $display("========================================");
        $display("Tests run : %0d", tests_run);
        $display("Failures  : %0d", failures);

        if (failures == 0) begin
            $display("MULTIPLIER VERIFICATION PASSED");
            $finish;
        end else begin
            $display("MULTIPLIER VERIFICATION FAILED");
            $fatal(1, "Multiplier testbench detected failures");
        end
    end

endmodule
