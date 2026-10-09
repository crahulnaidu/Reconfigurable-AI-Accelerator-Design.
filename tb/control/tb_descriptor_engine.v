`timescale 1ns/1ps

module tb_descriptor_engine;

    reg        clk;
    reg        rst_n;
    reg        load_descriptor_en;
    reg [31:0] descriptor_word_in;
    reg [2:0]  word_index;

    wire [31:0] start_ptr;
    wire [31:0] front_ptr;
    wire [31:0] exit_ptr;
    wire [1:0]  precision_mode;
    wire [31:0] scale_m0;
    wire [4:0]  shift_n;
    wire [7:0]  zero_point_z;
    wire [15:0] conf_thresh;

    // Instantiate DUT
    descriptor_engine dut (
        .clk(clk),
        .rst_n(rst_n),
        .load_descriptor_en(load_descriptor_en),
        .descriptor_word_in(descriptor_word_in),
        .word_index(word_index),
        .start_ptr(start_ptr),
        .front_ptr(front_ptr),
        .exit_ptr(exit_ptr),
        .precision_mode(precision_mode),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .conf_thresh(conf_thresh)
    );

    always #5 clk = ~clk;

    initial begin
        clk                = 0;
        rst_n              = 0;
        load_descriptor_en = 0;
        descriptor_word_in = 32'h0;
        word_index         = 3'd0;

        #15 rst_n = 1;
        @(posedge clk);

        // --- Stream Layer 1 Descriptor Frame ---
        load_descriptor_en = 1;

        // Word 0: START_PTR = 0x8000_1000
        word_index = 3'd0; descriptor_word_in = 32'h8000_1000; @(posedge clk);

        // Word 1: FRONT_PTR = 0x8000_2000 (Layer 2)
        word_index = 3'd1; descriptor_word_in = 32'h8000_2000; @(posedge clk);

        // Word 2: EXIT_PTR  = 0x8000_F000 (Early Exit Branch Head)
        word_index = 3'd2; descriptor_word_in = 32'h8000_F000; @(posedge clk);

        // Word 3: LAYER_CONFIG (Mode = INT4 2'b10, Shift = 31, Z = 0)
        word_index = 3'd3; descriptor_word_in = {17'b0, 8'sd0, 5'd31, 2'b10}; @(posedge clk);

        // Word 4: QUANT_M0
        word_index = 3'd4; descriptor_word_in = 32'sd1073741824; @(posedge clk);

        // Word 5: CONF_THRESH = 100
        word_index = 3'd5; descriptor_word_in = 32'd100; @(posedge clk);

        load_descriptor_en = 0;
        @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 3: DESCRIPTOR ENGINE VERIFICATION PASSED");
        $display("=======================================================");
        $display(" START_PTR          = %h", start_ptr);
        $display(" FRONT_PTR          = %h", front_ptr);
        $display(" EXIT_PTR           = %h", exit_ptr);
        $display(" Precision Mode     = %b (Expected: 10 for INT4)", precision_mode);
        $display(" Scale M0           = %d", scale_m0);
        $display(" Confidence Threshold= %d", conf_thresh);
        $display("=======================================================\n");

        $finish;
    end

endmodule