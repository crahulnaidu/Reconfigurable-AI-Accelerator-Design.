`timescale 1ns/1ps

module tb_descriptor_engine;
    reg clk;
    reg rst_n;
    reg load_descriptor_en;
    reg [31:0] descriptor_word_in;
    reg [4:0] word_index;

    wire [63:0] start_ptr, front_ptr, exit_ptr;
    wire [1:0] precision_mode;
    wire [31:0] scale_m0, conf_thresh;
    wire [4:0] shift_n;
    wire [7:0] zero_point_z;
    wire [63:0] weight_base, output_base, bias_base;
    wire [15:0] m_dim, n_dim, k_dim;
    wire [31:0] a_tile_stride_bytes, b_tile_stride_bytes, c_tile_stride_bytes;
    wire [31:0] deadline_cycles, layer_id;
    wire [5:0] cfg_flags;
    wire descriptor_done, descriptor_valid, config_error;
    wire [7:0] error_code;

    reg [31:0] words [0:31];
    integer i;
    integer tests_run;

    descriptor_engine #(.ADDR_WIDTH(32)) dut (
        .clk(clk), .rst_n(rst_n),
        .load_descriptor_en(load_descriptor_en),
        .descriptor_word_in(descriptor_word_in),
        .word_index(word_index),
        .start_ptr(start_ptr), .front_ptr(front_ptr), .exit_ptr(exit_ptr),
        .precision_mode(precision_mode), .scale_m0(scale_m0),
        .shift_n(shift_n), .zero_point_z(zero_point_z), .conf_thresh(conf_thresh),
        .weight_base(weight_base), .output_base(output_base), .bias_base(bias_base),
        .m_dim(m_dim), .n_dim(n_dim), .k_dim(k_dim),
        .a_tile_stride_bytes(a_tile_stride_bytes),
        .b_tile_stride_bytes(b_tile_stride_bytes),
        .c_tile_stride_bytes(c_tile_stride_bytes),
        .deadline_cycles(deadline_cycles), .layer_id(layer_id), .cfg_flags(cfg_flags),
        .descriptor_done(descriptor_done), .descriptor_valid(descriptor_valid),
        .config_error(config_error), .error_code(error_code)
    );

    always #5 clk = ~clk;

    task set_valid_descriptor;
        begin
            for (i=0; i<32; i=i+1) words[i] = 32'd0;
            words[0]  = 32'h8000_1000; // A_BASE low
            words[1]  = 32'h0000_0000; // A_BASE high
            words[2]  = 32'h8000_2000; // B_BASE low
            words[3]  = 32'h0000_0000;
            words[4]  = 32'h8000_3000; // C_BASE low
            words[5]  = 32'h0000_0000;
            words[6]  = 32'h8000_4000; // NEXT_DESC low (128B aligned)
            words[7]  = 32'h0000_0000;
            words[8]  = 32'h8000_5000; // EXIT_DESC low (128B aligned)
            words[9]  = 32'h0000_0000;
            words[10] = 32'h0000_0000; // Bias disabled
            words[11] = 32'h0000_0000;
            words[12] = 32'h0000_001D; // INT8 + zero skip + exit head + ReLU
            words[13] = 32'h4000_0000; // Q31 scale
            words[14] = 32'h0000_0400; // shift=4, zero point=0
            words[15] = 32'h0004_0008; // M=8, N=4
            words[16] = 32'd9;         // K=9, => ceil(9/2)*8 = 40B stride
            words[17] = 32'd40;        // A tile stride
            words[18] = 32'd40;        // B tile stride
            words[19] = 32'd16;        // C tile stride (INT8)
            words[20] = 32'd50;        // confidence margin threshold
            words[21] = 32'd700;       // deadline cycles
            words[22] = 32'h0000_1234; // layer id
            words[23] = 32'h0020_0001; // length=32, version=1
            // words[24..31] stay reserved zero.
        end
    endtask

    task send_descriptor;
        integer j;
        begin
            for (j=0; j<32; j=j+1) begin
                @(negedge clk);
                load_descriptor_en = 1'b1;
                word_index = j[4:0];
                descriptor_word_in = words[j];
                @(posedge clk);
                #1;
            end
            @(negedge clk);
            load_descriptor_en = 1'b0;
            word_index = 0;
            descriptor_word_in = 0;
            #1;
        end
    endtask

    task check;
        input condition;
        input [8*96-1:0] message;
        begin
            tests_run = tests_run + 1;
            if (condition !== 1'b1) begin
                $display("FAIL: %0s", message);
                $fatal(1, "Descriptor-engine assertion failed");
            end else begin
                $display("PASS: %0s", message);
            end
        end
    endtask

    initial begin
        clk=0; rst_n=0; load_descriptor_en=0;
        descriptor_word_in=0; word_index=0; tests_run=0;
        set_valid_descriptor();
        repeat (2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;

        check(!descriptor_valid && !config_error, "reset leaves descriptor invalid and no error");

        send_descriptor();
        check(descriptor_done, "descriptor_done pulses after word 31");
        check(descriptor_valid && !config_error, "valid descriptor accepted without error");
        check(start_ptr == 64'h0000_0000_8000_1000, "A_BASE decoded");
        check(weight_base == 64'h0000_0000_8000_2000, "B_BASE decoded");
        check(output_base == 64'h0000_0000_8000_3000, "C_BASE decoded");
        check(front_ptr == 64'h0000_0000_8000_4000, "NEXT_DESC decoded");
        check(exit_ptr == 64'h0000_0000_8000_5000, "EXIT_DESC decoded");
        check(precision_mode == 2'b01 && cfg_flags == 6'h1D, "precision and CFG flags decoded");
        check(scale_m0 == 32'h4000_0000 && shift_n == 5'd4 && zero_point_z == 8'd0,
              "requantization fields decoded");
        check(m_dim == 16'd8 && n_dim == 16'd4 && k_dim == 16'd9,
              "M/N/K dimensions decoded");
        check(a_tile_stride_bytes == 32'd40 && b_tile_stride_bytes == 32'd40 &&
              c_tile_stride_bytes == 32'd16, "tile strides decoded");
        check(conf_thresh == 32'd50 && deadline_cycles == 32'd700 &&
              layer_id == 32'h1234, "threshold/deadline/layer ID decoded");

        // Invalid precision (00 = not accepted by descriptor version 1).
        set_valid_descriptor();
        words[12] = 32'h0000_001C; // precision 00, other flags preserved
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h03, "unsupported precision rejected with ERR_PRECISION");
        check(start_ptr == 64'h0000_0000_8000_1000,
              "invalid descriptor does not overwrite last committed A_BASE");

        // Invalid descriptor: A_BASE not 8-byte aligned.
        set_valid_descriptor();
        words[0] = 32'h8000_1004;
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h05, "unaligned A_BASE rejected with ERR_ALIGNMENT");

        // Invalid descriptor: K=0.
        set_valid_descriptor();
        words[16] = 32'd0;
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h04, "zero K rejected with ERR_DIMENSION");

        // Invalid descriptor: nonzero reserved word.
        set_valid_descriptor();
        words[24] = 32'h1;
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h08, "reserved word rejected with ERR_RESERVED");

        // Invalid version/length must not be committed.
        set_valid_descriptor();
        words[23] = 32'h0020_0002; // version 2 is not supported by v1 parser
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h02, "bad descriptor version rejected with ERR_VERSION");

        // Invalid A stride is too short for K=9 in INT8 mode.
        set_valid_descriptor();
        words[17] = 32'd32; // minimum is ceil(9/2)*8 = 40 bytes
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h06, "undersized A tile stride rejected with ERR_STRIDE");

        // Address-width validation: default ADDR_WIDTH=32 rejects high pointer words.
        set_valid_descriptor();
        words[1] = 32'd1;
        send_descriptor();
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h07, "nonzero high address word rejected on 32-bit target");

        // Word-order error: abort a frame after receiving only words 0 and 2.
        @(negedge clk); load_descriptor_en=1; word_index=0; descriptor_word_in=words[0];
        @(posedge clk); #1;
        @(negedge clk); word_index=2; descriptor_word_in=words[2];
        @(posedge clk); #1;
        check(descriptor_done && !descriptor_valid && config_error &&
              error_code == 8'h01, "out-of-order word rejected with ERR_WORD_ORDER");
        @(negedge clk); load_descriptor_en=0;

        $display("");
        $display("========================================");
        $display("DESCRIPTOR ENGINE TEST SUMMARY");
        $display("Checks run: %0d", tests_run);
        $display("Failures: 0");
        $display("DESCRIPTOR ENGINE VERIFICATION PASSED");
        $display("========================================");
        $finish;
    end
endmodule
