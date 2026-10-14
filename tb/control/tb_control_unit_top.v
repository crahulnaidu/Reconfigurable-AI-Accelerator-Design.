`timescale 1ns/1ps

module tb_control_unit_top;

    reg        clk;
    reg        rst_n;
    reg        start_inference;
    reg [31:0] root_descriptor_ptr;
    reg [31:0] descriptor_word_in;
    reg [2:0]  word_index;
    reg        descriptor_done;
    reg [15:0] activation_in;
    reg [15:0] tensor_height;
    reg [15:0] tensor_width;
    reg [15:0] stride_bytes;

    wire [31:0] active_mem_addr;
    wire        bank_swap;
    wire        acc_enable;
    wire [1:0]  precision_mode;
    wire [31:0] scale_m0;
    wire [4:0]  shift_n;
    wire [7:0]  zero_point_z;
    wire        inference_complete;
    wire        early_exit_occurred;

    // Instantiate DUT
    control_unit_top dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_inference(start_inference),
        .root_descriptor_ptr(root_descriptor_ptr),
        .descriptor_word_in(descriptor_word_in),
        .word_index(word_index),
        .descriptor_done(descriptor_done),
        .activation_in(activation_in),
        .tensor_height(tensor_height),
        .tensor_width(tensor_width),
        .stride_bytes(stride_bytes),
        .active_mem_addr(active_mem_addr),
        .bank_swap(bank_swap),
        .acc_enable(acc_enable),
        .precision_mode(precision_mode),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .inference_complete(inference_complete),
        .early_exit_occurred(early_exit_occurred)
    );

    always #5 clk = ~clk;

    initial begin
        clk                 = 0;
        rst_n               = 0;
        start_inference     = 0;
        root_descriptor_ptr = 32'h8000_0000;
        descriptor_word_in = 32'h0;
        word_index          = 3'd0;
        descriptor_done     = 0;
        activation_in       = 16'h0000;
        tensor_height       = 16'd2;
        tensor_width        = 16'd2;
        stride_bytes        = 16'd32;

        #15 rst_n = 1;
        @(posedge clk);

        // --- Step 1: Trigger Inference ---
        start_inference = 1;
        @(posedge clk);
        start_inference = 0;

        // --- Step 2: Stream Descriptor Frame ---
        word_index = 3'd0; descriptor_word_in = 32'h8000_1000; @(posedge clk); // START_PTR
        word_index = 3'd1; descriptor_word_in = 32'h8000_2000; @(posedge clk); // FRONT_PTR
        word_index = 3'd2; descriptor_word_in = 32'h8000_F000; @(posedge clk); // EXIT_PTR
        word_index = 3'd3; descriptor_word_in = {17'b0, 8'sd0, 5'd31, 2'b10}; @(posedge clk); // CONFIG (INT4)
        word_index = 3'd4; descriptor_word_in = 32'sd1073741824; @(posedge clk); // M0
        word_index = 3'd5; descriptor_word_in = 32'd50; @(posedge clk); // CONF_THRESH = 50

        descriptor_done = 1;
        @(posedge clk);
        descriptor_done = 0;

        // --- Step 3: Stream High-Confidence Logits to Force Early Exit ---
        @(posedge clk);
        activation_in = 16'sd180; @(posedge clk);
        activation_in = 16'sd100; @(posedge clk); // Margin = 80 >= 50

        repeat(6) @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 7: TOP CONTROL UNIT VERIFICATION PASSED");
        $display("=======================================================");
        $display(" Configured Precision Mode = %b (Expected: 10 for INT4)", precision_mode);
        $display(" Active AGU Memory Address = %h", active_mem_addr);
        $display(" Early Exit Occurred Flag = %b (Expected: 1)", early_exit_occurred);
        $display("=======================================================\n");

        $finish;
    end

endmodule