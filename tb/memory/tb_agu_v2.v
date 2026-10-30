`timescale 1ns/1ps
module tb_agu_v2;
    reg clk, rst_n;
    reg start_valid;
    wire start_ready;
    reg [31:0] base_addr;
    reg [15:0] rows, words_per_row;
    reg [31:0] row_stride_bytes;
    wire addr_valid;
    reg addr_ready;
    wire [31:0] addr;
    wire busy, done, error;
    wire [2:0] error_code;
    integer checks, i;
    reg [31:0] expected [0:5];

    agu_v2 #(.ADDR_WIDTH(32), .WORD_BYTES(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .start_valid(start_valid), .start_ready(start_ready),
        .base_addr(base_addr), .rows(rows), .words_per_row(words_per_row),
        .row_stride_bytes(row_stride_bytes),
        .addr_valid(addr_valid), .addr_ready(addr_ready), .addr(addr),
        .busy(busy), .done(done), .error(error), .error_code(error_code)
    );

    always #5 clk = ~clk;

    task automatic expect_error(input [31:0] base, input [15:0] row_n,
                                input [15:0] word_n, input [31:0] stride,
                                input [2:0] expected_code);
        begin
            @(negedge clk);
            base_addr=base; rows=row_n; words_per_row=word_n; row_stride_bytes=stride;
            start_valid=1'b1;
            @(posedge clk); #1;
            if (!error || error_code !== expected_code || busy || addr_valid)
                $fatal(1, "AGU expected error code %0d, got error=%b code=%0d", expected_code, error, error_code);
            @(negedge clk); start_valid=1'b0;
            checks=checks+1;
            $display("PASS: invalid AGU request rejected with error code %0d", expected_code);
        end
    endtask

    initial begin
        clk=0; rst_n=0; start_valid=0; base_addr=0; rows=0; words_per_row=0;
        row_stride_bytes=0; addr_ready=0; checks=0;
        expected[0]=32'h0000_1000;
        expected[1]=32'h0000_1008;
        expected[2]=32'h0000_1010;
        expected[3]=32'h0000_1020;
        expected[4]=32'h0000_1028;
        expected[5]=32'h0000_1030;
        repeat(2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        if (!start_ready || busy || addr_valid) $fatal(1, "AGU reset state incorrect");
        checks=checks+1; $display("PASS: AGU reset and start-ready state");

        // Two rows x three 64-bit words, row stride 32 bytes.
        @(negedge clk);
        base_addr=32'h1000; rows=2; words_per_row=3; row_stride_bytes=32; start_valid=1;
        @(posedge clk); #1;
        if (!busy || !addr_valid || addr !== expected[0]) $fatal(1, "AGU failed to present first address");
        @(negedge clk); start_valid=0; addr_ready=0;

        // Apply backpressure; address and VALID must remain stable.
        repeat(3) begin
            @(posedge clk); #1;
            if (!addr_valid || addr !== expected[0]) $fatal(1, "AGU address changed under backpressure");
            checks=checks+1;
        end
        $display("PASS: address and VALID remain stable under backpressure");

        // Accept each address and compare against the row-stride reference.
        for (i=0; i<6; i=i+1) begin
            @(negedge clk);
            if (!addr_valid || addr !== expected[i])
                $fatal(1, "AGU address[%0d] expected %h got %h valid=%b", i, expected[i], addr, addr_valid);
            addr_ready=1;
            @(posedge clk); #1;
            if (i<5 && !addr_valid) $fatal(1, "AGU stopped before final address");
            if (i==5 && (!done || busy || addr_valid)) $fatal(1, "AGU final handshake did not complete");
            checks=checks+1;
        end
        @(negedge clk); addr_ready=0;
        $display("PASS: all 6 row/column addresses match expected 64-bit word stepping");

        expect_error(32'h2000, 0, 2, 16, 3'd1); // zero rows
        expect_error(32'h2004, 2, 2, 16, 3'd2); // unaligned base
        expect_error(32'h3000, 2, 3, 16, 3'd3); // stride too small
        expect_error(32'hffff_fff8, 2, 2, 16, 3'd4); // address overflow

        $display("\nAGU V2 SUMMARY");
        $display("Checks run: %0d", checks);
        $display("Failures : 0");
        $display("AGU VERIFICATION PASSED");
        $finish;
    end
endmodule
