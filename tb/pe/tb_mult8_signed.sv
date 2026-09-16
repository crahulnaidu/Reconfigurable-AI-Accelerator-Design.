module tb_mult8_signed;

   // Use 'logic' instead of reg/wire for SystemVerilog compliance
   logic signed [7:0] a_in;
   logic signed [7:0] b_in;
   logic signed [15:0] c_out;
   
   // Variable to hold the expected calculation for automated checks
   logic signed [15:0] expected_c;

   // Instantiate the Design Under Test (DUT)
   mult8_sig uut (
      .a_in(a_in),
      .b_in(b_in),
      .c_out(c_out)
   );

   initial begin
      $display("=== Starting 8-bit Signed Multiplier Verification ===");

      // ---------------------------------------------------------
      // 1. Manual Edge Cases
      // ---------------------------------------------------------
      
      // Case A: Positive x Positive (7 * 3)
      a_in = 8'sd7;
      b_in = 8'sd3;
      #10;
      expected_c = a_in * b_in;
      assert (c_out === expected_c) 
         else $error("Edge Case 1 Failed: %0d * %0d = %0d (Expected: %0d)", a_in, b_in, c_out, expected_c);

      // Case B: Negative x Positive (-125 * 2)
      a_in = -8'sd125;
      b_in = 8'sd2;
      #10;
      expected_c = a_in * b_in;
      assert (c_out === expected_c) 
         else $error("Edge Case 2 Failed: %0d * %0d = %0d (Expected: %0d)", a_in, b_in, c_out, expected_c);

      // Case C: Minimum Negative x 1 (-128 * 1)
      a_in = -8'sd128;
      b_in = 8'sd1;
      #10;
      expected_c = a_in * b_in;
      assert (c_out === expected_c) 
         else $error("Edge Case 3 Failed: %0d * %0d = %0d (Expected: %0d)", a_in, b_in, c_out, expected_c);

      // ---------------------------------------------------------
      // 2. Automated Loop with 100 Random Signed Values
      // ---------------------------------------------------------
      $display("=== Running 100 Random Test Cases ===");
      
      for (int i = 0; i < 100; i++) begin
         // $urandom_range generates random numbers within the 8-bit signed range (-128 to 127)
         a_in = $urandom_range(-128, 127);
         b_in = $urandom_range(-128, 127);
         #10;
         
         // Calculate gold standard expected output behaviorally
         expected_c = a_in * b_in;
         
         // Explicit SystemVerilog Assertion Check
         assert (c_out === expected_c) else begin
            $error("Random Test Mismatch at iteration %0d: %0d * %0d = %0d (Expected: %0d)", 
                   i, a_in, b_in, c_out, expected_c);
         end
      end

      $display("=== Test Completed Successfully with No Errors ===");
      $finish;
   end

endmodule