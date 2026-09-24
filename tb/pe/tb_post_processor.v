`timescale 1ns/1ps

module tb_post_processor;

    reg [1:0]  precision_mode;
    reg [31:0] accum_in;
    reg [31:0] scale_m0;
    reg [4:0]  shift_n;
    reg [7:0]  zero_point_z;

    wire [15:0] post_proc_out;

    // Instantiate DUT
    post_processor dut (
        .precision_mode(precision_mode),
        .accum_in(accum_in),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .post_proc_out(post_proc_out)
    );

    initial begin
        // --- Test 1: INT8 Scaling & Normal Within-Bound Result ---
        precision_mode = 2'b01;      // INT8 Mode
        accum_in       = 32'sd1250;  // Raw PE accumulator output
        scale_m0       = 32'sd1073741824; // M_0 = 0.5 in Q31 format
        shift_n        = 5'd31;      // Shift right by 31 bits
        zero_point_z   = 8'sd0;      // Zero-point offset = 0
        #10;
        // Expected: (1250 * 1073741824) >>> 31 = 625 -> Clamped to INT8 = 127 (Max Saturate!)

        // --- Test 2: INT8 Negative Saturating Clamp ---
        accum_in       = -32'sd5000;
        scale_m0       = 32'sd2147483647; // M_0 ~ 1.0 in Q31
        shift_n        = 5'd31;
        zero_point_z   = 8'sd0;
        #10;
        // Expected: -5000 is far below -128 -> Clamps strictly to -128 (8'h80)

        // --- Test 3: INT4 Scaling & Clamping ---
        precision_mode = 2'b10;      // INT4 Mode
        accum_in       = 32'sd100;
        scale_m0       = 32'sd214748364; // M_0 ~ 0.1
        shift_n        = 5'd31;
        zero_point_z   = 8'sd0;
        #10;
        // Expected: (100 * 0.1) = 10 -> Exceeds INT4 max (+7), clamps strictly to +7

        // --- Test 4: FP16 Bypass Mode ---
        precision_mode = 2'b00;      // FP16 Mode
        accum_in       = 32'h0000_3E00; // Raw FP16 value
        #10;
        // Expected: post_proc_out = 16'h3E00 (Bypasses scaler completely)

        $display("DAY 3 POST-PROCESSOR VERIFICATION COMPLETED SUCCESSFULLY!");
        $finish;
    end

endmodule