`timescale 1ns/1ps
module tb_ping_pong_sram_v2;
    reg clk, rst_n;
    reg dma_write_valid;
    wire dma_write_ready;
    reg [7:0] dma_write_addr;
    reg [63:0] dma_write_data;
    reg dma_commit;
    wire dma_commit_ready;
    wire prefetch_complete;
    reg bank_swap_req;
    wire bank_swap_ack, bank_swap_rejected, active_bank;
    reg compute_read_en;
    reg [7:0] compute_read_addr;
    wire compute_read_valid;
    wire [63:0] compute_read_data;
    integer checks;

    ping_pong_sram_v2 #(.DATA_WIDTH(64), .ADDR_WIDTH(8)) dut (
        .clk(clk), .rst_n(rst_n),
        .dma_write_valid(dma_write_valid), .dma_write_ready(dma_write_ready),
        .dma_write_addr(dma_write_addr), .dma_write_data(dma_write_data),
        .dma_commit(dma_commit), .dma_commit_ready(dma_commit_ready),
        .prefetch_complete(prefetch_complete),
        .bank_swap_req(bank_swap_req), .bank_swap_ack(bank_swap_ack),
        .bank_swap_rejected(bank_swap_rejected), .active_bank(active_bank),
        .compute_read_en(compute_read_en), .compute_read_addr(compute_read_addr),
        .compute_read_valid(compute_read_valid), .compute_read_data(compute_read_data)
    );

    always #5 clk = ~clk;

    task automatic write_word(input [7:0] address, input [63:0] data);
        begin
            @(negedge clk);
            if (!dma_write_ready) $fatal(1, "DMA write unexpectedly not ready");
            dma_write_valid = 1'b1;
            dma_write_addr = address;
            dma_write_data = data;
            @(posedge clk); #1;
            @(negedge clk);
            dma_write_valid = 1'b0;
            checks = checks + 1;
            $display("PASS: inactive-bank DMA write accepted at address %h", address);
        end
    endtask

    task automatic commit_bank;
        begin
            @(negedge clk);
            if (!dma_commit_ready) $fatal(1, "DMA commit unexpectedly not ready");
            dma_commit = 1'b1;
            @(posedge clk); #1;
            if (!prefetch_complete) $fatal(1, "prefetch_complete did not assert");
            @(negedge clk); dma_commit = 1'b0;
            if (dma_write_ready) $fatal(1, "DMA writes must be blocked after commit");
            checks = checks + 1;
            $display("PASS: bank commit locks the completed inactive bank");
        end
    endtask

    task automatic swap_bank;
        begin
            @(negedge clk); bank_swap_req = 1'b1;
            @(posedge clk); #1;
            if (!bank_swap_ack || active_bank !== 1'b1)
                $fatal(1, "first bank swap did not activate bank 1");
            @(negedge clk); bank_swap_req = 1'b0;
            checks = checks + 1;
            $display("PASS: committed bank becomes active on swap");
        end
    endtask

    task automatic read_check(input [7:0] address, input [63:0] expected);
        begin
            @(negedge clk);
            compute_read_addr = address;
            compute_read_en = 1'b1;
            @(posedge clk); #1;
            if (!compute_read_valid) $fatal(1, "synchronous read-valid missing");
            if (compute_read_data !== expected)
                $fatal(1, "read mismatch at %h expected %h got %h", address, expected, compute_read_data);
            @(negedge clk); compute_read_en = 1'b0;
            checks = checks + 1;
            $display("PASS: active-bank read %h = %h", address, expected);
        end
    endtask

    initial begin
        clk=0; rst_n=0; dma_write_valid=0; dma_write_addr=0; dma_write_data=0;
        dma_commit=0; bank_swap_req=0; compute_read_en=0; compute_read_addr=0; checks=0;
        repeat(2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        if (active_bank !== 1'b0 || prefetch_complete !== 1'b0)
            $fatal(1, "reset state incorrect");
        checks=checks+1; $display("PASS: reset selects bank 0 and clears ownership flags");

        // Fill inactive bank 1 while bank 0 remains the compute bank.
        write_word(8'h00, 64'hAAAA_BBBB_CCCC_DDDD);
        write_word(8'h01, 64'h1111_2222_3333_4444);
        commit_bank();
        if (dma_write_ready) $fatal(1, "writes accepted after commit");
        swap_bank();
        read_check(8'h00, 64'hAAAA_BBBB_CCCC_DDDD);
        read_check(8'h01, 64'h1111_2222_3333_4444);

        // Now DMA fills bank 0 while compute continues reading bank 1.
        write_word(8'h00, 64'h0123_4567_89AB_CDEF);
        read_check(8'h00, 64'hAAAA_BBBB_CCCC_DDDD);
        commit_bank();
        @(negedge clk); bank_swap_req=1'b1;
        @(posedge clk); #1;
        if (!bank_swap_ack || active_bank !== 1'b0)
            $fatal(1, "second bank swap did not activate bank 0");
        @(negedge clk); bank_swap_req=1'b0;
        read_check(8'h00, 64'h0123_4567_89AB_CDEF);
        checks=checks+1; $display("PASS: consecutive bank ownership reversal");

        // A swap without a completed prefetch must be rejected.
        @(negedge clk); bank_swap_req=1'b1;
        @(posedge clk); #1;
        if (!bank_swap_rejected || active_bank !== 1'b0)
            $fatal(1, "uncommitted bank swap was not rejected");
        @(negedge clk); bank_swap_req=1'b0;
        checks=checks+1; $display("PASS: swap rejected when inactive bank is not committed");

        $display("\nPING-PONG SRAM V2 SUMMARY");
        $display("Checks run: %0d", checks);
        $display("Failures : 0");
        $display("PING-PONG SRAM VERIFICATION PASSED");
        $finish;
    end
endmodule
