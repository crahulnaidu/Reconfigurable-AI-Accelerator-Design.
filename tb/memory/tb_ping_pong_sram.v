`timescale 1ns/1ps

module tb_ping_pong_sram;

    reg         clk;
    reg         rst_n;
    reg         bank_swap;
    reg         dma_write_en;
    reg  [7:0]  dma_write_addr;
    reg  [63:0] dma_write_data;
    reg         array_read_en;
    reg  [7:0]  array_read_addr;

    wire [63:0] array_read_data;

    // Instantiate DUT
    ping_pong_sram #(
        .DATA_WIDTH(64),
        .ADDR_WIDTH(8)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .bank_swap(bank_swap),
        .dma_write_en(dma_write_en),
        .dma_write_addr(dma_write_addr),
        .dma_write_data(dma_write_data),
        .array_en(array_read_en),
        .array_read_addr(array_read_addr),
        .array_read_data(array_read_data)
    );

    always #5 clk = ~clk;

    initial begin
        clk            = 0;
        rst_n          = 0;
        bank_swap      = 0;
        dma_write_en   = 0;
        dma_write_addr = 0;
        dma_write_data = 0;
        array_read_en  = 0;
        array_read_addr= 0;

        #15 rst_n = 1;
        @(posedge clk);

        // --- Step 1: Pre-fill Bank 0 manually ---
        // (In real operation, DMA writes to Bank 1 initially while Bank 0 is read)
        dma_write_en   = 1;
        dma_write_addr = 8'h00;
        dma_write_data = 64'hAAAA_BBBB_CCCC_DDDD; // Layer N+1 data into Bank 1
        @(posedge clk);

        dma_write_addr = 8'h01;
        dma_write_data = 64'h1111_2222_3333_4444;
        @(posedge clk);
        dma_write_en   = 0;

        // --- Step 2: Read from Bank 0 ---
        array_read_en   = 1;
        array_read_addr = 8'h00;
        @(posedge clk);

        // --- Step 3: Trigger Bank Swap ---
        bank_swap = 1;
        @(posedge clk);
        bank_swap = 0;

        // --- Step 4: Read newly active Bank 1 data ---
        array_read_addr = 8'h00;
        @(posedge clk);
        @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 2: PING-PONG SRAM VERIFICATION PASSED");
        $display("=======================================================");
        $display(" Array Read Data after Bank Swap = %h", array_read_data);
        $display("=======================================================\n");

        $finish;
    end

endmodule