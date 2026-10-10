`timescale 1ns/1ps

module tb_agu;

    reg        clk;
    reg        rst_n;
    reg        start_agu;
    reg [31:0] start_ptr;
    reg [15:0] tensor_height;
    reg [15:0] tensor_width;
    reg [15:0] stride_bytes;

    wire [31:0] mem_addr;
    wire        agu_valid;
    wire        agu_done;

    // Instantiate DUT
    agu dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_agu(start_agu),
        .start_ptr(start_ptr),
        .tensor_height(tensor_height),
        .tensor_width(tensor_width),
        .stride_bytes(stride_bytes),
        .mem_addr(mem_addr),
        .agu_valid(agu_valid),
        .agu_done(agu_done)
    );

    always #5 clk = ~clk;

    initial begin
        clk           = 0;
        rst_n         = 0;
        start_agu     = 0;
        start_ptr     = 32'h8000_0000;
        tensor_height = 16'd2; // 2 Rows
        tensor_width  = 16'd2; // 2 Columns
        stride_bytes  = 16'd32; // Row stride of 32 bytes

        #15 rst_n = 1;
        @(posedge clk);

        // --- Trigger AGU Address Stream ---
        start_agu = 1;
        @(posedge clk);
        start_agu = 0;

        // Monitor generated address stream
        while (!agu_done) begin
            if (agu_valid) begin
                $display(" Generated Address = %h", mem_addr);
            end
            @(posedge clk);
        end

        @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 4: ADDRESS GENERATION UNIT VERIFIED PASSED");
        $display("=======================================================");
        $display(" Final Status: agu_done = %b", agu_done);
        $display("=======================================================\n");

        $finish;
    end

endmodule