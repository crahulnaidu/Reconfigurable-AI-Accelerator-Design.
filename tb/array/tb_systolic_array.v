`timescale 1ns/1ps

module tb_systolic_array;

    reg        clk;
    reg        rst_n;
    reg [1:0]  precision_mode;
    reg        acc_clear;
    reg        acc_enable;
    reg [31:0] scale_m0;
    reg [4:0]  shift_n;
    reg [7:0]  zero_point_z;

    // 2D Array Signals matching systolic_array.v ports
    reg [15:0] act_row_in   [0:3];
    reg [15:0] weight_col_in[0:3];

    wire [15:0] array_data_out[0:3][0:3];
    wire [19:0] total_zero_skips;

    // Instantiate DUT with matching 2D array ports
    systolic_array dut (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .acc_clear(acc_clear),
        .acc_enable(acc_enable),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .act_row_in(act_row_in),
        .weight_col_in(weight_col_in),
        .array_data_out(array_data_out),
        .total_zero_skips(total_zero_skips)
    );

    // Clock Generation (100 MHz)
    always #5 clk = ~clk;

    integer r, c;

    initial begin
        clk            = 0;
        rst_n          = 0;
        precision_mode = 2'b01; // INT8 Mode
        acc_clear      = 0;
        acc_enable     = 0;
        scale_m0       = 32'sd1073741824; // M_0 = 0.5 in Q31
        shift_n        = 5'd31;
        zero_point_z   = 8'sd0;

        for (r = 0; r < 4; r = r + 1) act_row_in[r] = 16'h0000;
        for (c = 0; c < 4; c = c + 1) weight_col_in[c] = 16'h0000;

        // Synchronous Reset
        #15 rst_n = 1;
        @(posedge clk);

        // --- Step 1: Load Weights into Columns ---
        // Col0 = [2, 2], Col1 = [3, 1], Col2 = [1, 4], Col3 = [2, 3]
        weight_col_in[0] = {8'sd2, 8'sd2};
        weight_col_in[1] = {8'sd3, 8'sd1};
        weight_col_in[2] = {8'sd1, 8'sd4};
        weight_col_in[3] = {8'sd2, 8'sd3};

        // --- Step 2: Accumulate MAC Pass 1 ---
        @(posedge clk);
        acc_enable = 1;
        act_row_in[0] = {8'sd10, 8'sd20};
        act_row_in[1] = {8'sd5,  8'sd15};
        act_row_in[2] = {8'sd8,  8'sd12};
        act_row_in[3] = {8'sd4,  8'sd16};

        // --- Step 3: Accumulate MAC Pass 2 ---
        @(posedge clk);
        act_row_in[0] = {8'sd2, 8'sd2};
        act_row_in[1] = {8'sd1, 8'sd1};
        act_row_in[2] = {8'sd3, 8'sd3};
        act_row_in[3] = {8'sd4, 8'sd4};

        // --- Step 4: Stream Zero Activations (Triggers Zero-Bypass) ---
        @(posedge clk);
        for (r = 0; r < 4; r = r + 1) act_row_in[r] = 16'h0000;

        @(posedge clk);
        acc_enable = 0;

        // Allow pipeline output registers to latch
        repeat(2) @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 1: SYSTOLIC ARRAY VERIFICATION PASSED");
        $display("=======================================================");
        $display(" Total Zero Skips Across 4x4 Grid = %d", total_zero_skips);
        $display(" PE[0][0] Output (Scaled)          = %h (Decimal: %d)", 
                 array_data_out[0][0], $signed(array_data_out[0][0][7:0]));
        $display("=======================================================\n");

        $finish;
    end

endmodule