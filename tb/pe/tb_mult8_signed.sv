`timescale 1ns/1ps

module tb_mult8_signed;

    logic signed [7:0]  a_in;
    logic signed [7:0]  b_in;
    logic signed [15:0] c_out;

    logic signed [15:0] expected_c;

    integer tests_run;
    integer failures;
    integer i;

    mult8_sig uut (
        .a_in(a_in),
        .b_in(b_in),
        .c_out(c_out)
    );

    task automatic check_result(
        input logic signed [7:0]  a,
        input logic signed [7:0]  b
    );
        begin
            a_in = a;
            b_in = b;

            #1;

            expected_c = a * b;
            tests_run = tests_run + 1;

            if (c_out !== expected_c) begin
                failures = failures + 1;

                $display(
                    "FAIL: a=%0d b=%0d actual=%0d expected=%0d",
                    a_in, b_in, c_out, expected_c
                );
            end
        end
    endtask

    initial begin
        tests_run = 0;
        failures  = 0;

        $display("=== Signed 8-bit Multiplier Verification ===");

        // Directed tests: boundary values and sign combinations.
        check_result( 8'sd0,    8'sd0);
        check_result( 8'sd1,    8'sd1);
        check_result( 8'sd7,    8'sd3);
        check_result(-8'sd125,  8'sd2);
        check_result(-8'sd128,  8'sd1);
        check_result(-8'sd128, -8'sd1);
        check_result(-8'sd128, -8'sd128);
        check_result(-8'sd128,  8'sd127);
        check_result( 8'sd127,  8'sd127);
        check_result( 8'sd127, -8'sd128);

        // Exhaustively test every possible value of a against
        // representative boundary and sign-sensitive values of b.
        for (i = -128; i <= 127; i = i + 1) begin
            check_result(i,  8'sd0);
            check_result(i,  8'sd1);
            check_result(i, -8'sd1);
            check_result(i,  8'sd127);
            check_result(i, -8'sd128);
        end

        // Random signed bit patterns.
        for (i = 0; i < 1000; i = i + 1) begin
            check_result($signed($urandom), $signed($urandom));
        end

        $display("Tests run: %0d", tests_run);
        $display("Failures : %0d", failures);

        if (failures == 0) begin
            $display("PASS: All multiplier comparisons matched.");
            $finish;
        end
        else begin
            $display("FAIL: Multiplier verification failed.");
            $fatal(1, "Found %0d failing comparisons.", failures);
        end
    end

endmodule
