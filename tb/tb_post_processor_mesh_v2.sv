`timescale 1ns/1ps
module tb_post_processor_mesh_v2;
    reg clk, rst_n, clear;
    reg [1:0] precision_mode;
    reg [31:0] scale_m0;
    reg [4:0] shift_n;
    reg [7:0] zero_point_z;
    reg [127:0] pe_accum_in [0:3][0:3];
    reg [15:0] pe_result_valid, result_ready;
    wire [15:0] result_valid;
    wire [15:0] result_data [0:3][0:3];
    wire tile_done;
    wire [31:0] saturation_count;

    integer checks, r, c;

    post_processor_mesh_v2 dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .precision_mode(precision_mode), .scale_m0(scale_m0),
        .shift_n(shift_n), .zero_point_z(zero_point_z),
        .pe_accum_in(pe_accum_in), .pe_result_valid(pe_result_valid),
        .result_ready(result_ready), .result_valid(result_valid),
        .result_data(result_data), .tile_done(tile_done),
        .saturation_count(saturation_count)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*100-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("FAIL: %0s", message);
                $fatal(1, "post-processor assertion failed");
            end else $display("PASS: %0s", message);
        end
    endtask

    task clear_results;
        begin
            @(negedge clk); clear = 1'b1; pe_result_valid = 16'h0000;
            result_ready = 16'h0000;
            @(posedge clk); #1;
            check(result_valid == 16'h0000 && !tile_done && saturation_count == 0,
                  "clear resets valid state, tile completion and saturation counter");
            @(negedge clk); clear = 1'b0;
        end
    endtask

    task capture_all;
        begin
            @(negedge clk); pe_result_valid = 16'hffff; result_ready = 16'h0000;
            @(posedge clk); #1;
            check(result_valid == 16'hffff && tile_done,
                  "all sixteen PE outputs captured and held under backpressure");
            @(negedge clk); pe_result_valid = 16'h0000;
            @(posedge clk); #1;
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; clear = 0;
        precision_mode = 2'b01; scale_m0 = 32'd1;
        shift_n = 5'd0; zero_point_z = 8'd0;
        pe_result_valid = 0; result_ready = 0; checks = 0;
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = 128'd0;

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk); #1;

        // INT8: sum the two packed partial-K accumulators (5 + -2 = 3).
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = {64'd0, 32'hffff_fffe, 32'd5};
        capture_all();
        check(result_data[0][0] == 16'h0003 && saturation_count == 0,
              "INT8 two-lane reduction produces scalar result 3");
        @(negedge clk); result_ready = 16'hffff;
        @(posedge clk); #1;
        check(result_valid == 16'h0000, "result valid clears after downstream acceptance");

        clear_results();
        // INT8 negative result verifies sign extension on the 16-bit output.
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = {64'd0, 32'hffff_fffd, 32'hffff_fffc};
        capture_all();
        check(result_data[0][0] == 16'hfff9,
              "negative INT8 scalar result is correctly sign-extended");

        clear_results();
        // INT8 saturation: 100 + 100 = 200 -> 127 for each of 16 outputs.
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = {64'd0, 32'd100, 32'd100};
        capture_all();
        check(result_data[0][0] == 16'h007f && saturation_count == 32'd16,
              "INT8 saturation clamps all sixteen outputs and counts each clamp");

        clear_results();
        // INT4: four packed partial-K lanes add to 4.
        precision_mode = 2'b10;
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = {32'd0, 32'd3, 32'hffff_ffff, 32'd2};
        capture_all();
        check(result_data[0][0] == 16'h0004 && saturation_count == 0,
              "INT4 four-lane reduction produces scalar result 4");

        clear_results();
        // INT4 saturation: 7 + 1 = 8 -> 7.
        for (r=0; r<4; r=r+1)
            for (c=0; c<4; c=c+1)
                pe_accum_in[r][c] = {32'd0, 32'd0, 32'd1, 32'd7};
        capture_all();
        check(result_data[0][0] == 16'h0007 && saturation_count == 32'd16,
              "INT4 saturation clamps all sixteen outputs and counts each clamp");

        $display("");
        $display("POST-PROCESSOR MESH V2 SUMMARY");
        $display("Checks run: %0d", checks);
        $display("Failures : 0");
        $display("POST-PROCESSOR MESH VERIFICATION PASSED");
        $finish;
    end
endmodule
