module agu (
    input  wire        clk,
    input  wire        rst_n,

    // Control Inputs from Sequencer FSM / Descriptor Engine
    input  wire        start_agu,       // Trigger signal to start address generation
    input  wire [31:0] start_ptr,       // Base physical memory address from layer descriptor
    input  wire [15:0] tensor_height,   // Matrix height (rows)
    input  wire [15:0] tensor_width,    // Matrix width (columns)
    input  wire [15:0] stride_bytes,    // Byte stride between adjacent matrix rows

    // Memory Access & Handshaking Outputs
    output reg  [31:0] mem_addr,        // Generated physical SRAM/DRAM address
    output reg         agu_valid,       // High when mem_addr holds a valid address
    output reg         agu_done         // High on the final cycle of address generation
);

    reg [15:0] row_cnt;
    reg [15:0] col_cnt;
    reg        busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_addr  <= 32'h0000_0000;
            agu_valid <= 1'b0;
            agu_done  <= 1'b0;
            row_cnt   <= 16'd0;
            col_cnt   <= 16'd0;
            busy      <= 1 'b0;
        end else if (start_agu && !busy) begin
            busy      <= 1'b1;
            agu_valid <= 1'b1;
            agu_done  <= 1'b0;
            row_cnt   <= 16'd0;
            col_cnt   <= 16'd0;
            mem_addr  <= start_ptr;
        end else if (busy) begin
            if (col_cnt + 1'b1 < tensor_width) begin
                col_cnt  <= col_cnt + 1'b1;
                mem_addr <= mem_addr + 32'd8; // Next 64-bit word within row
            end else begin
                col_cnt <= 16'd0;
                if (row_cnt + 1'b1 < tensor_height) begin
                    row_cnt  <= row_cnt + 1'b1;
                    mem_addr <= start_ptr + ((row_cnt + 1'b1) * stride_bytes);
                end else begin
                    // Final element reached
                    busy      <= 1'b0;
                    agu_valid <= 1'b0;
                    agu_done  <= 1'b1;
                end
            end
        end else begin
            agu_done <= 1'b0;
        end
    end

endmodule