module ping_pong_sram #(
    parameter DATA_WIDTH=64,
    parameter ADDR_WIDTH=8
)(
    input wire clk,
    input wire rst_n,

    input wire bank_swap,

    input wire dma_write_en,
    input wire [ADDR_WIDTH-1:0] dma_write_addr,
    input wire [DATA_WIDTH-1:0] dma_write_data,

    input wire array_en,
    input wire [ADDR_WIDTH-1:0] array_read_addr,
    output reg [DATA_WIDTH-1:0] array_read_data
);

    reg bank_select;

    always @(posedge(clk) or negedge(rst_n))begin
        if (!rst_n)begin
            bank_select<=1'b0;
        end else if(bank_swap) begin
            bank_select<=~bank_select;
        end
    end

    reg [DATA_WIDTH-1:0] sram_bank0 [1<<(ADDR_WIDTH)-1];
    reg [DATA_WIDTH-1:0] sram_bank1 [1<<(ADDR_WIDTH)-1];

    always @(posedge(clk)) begin
        if (array_en) begin
            if (bank_select == 1'b0) begin 
                array_read_data<=sram_bank0[array_read_addr];
            end else if (bank_swap) begin
                array_read_data<=sram_bank1[array_read_addr];
            end
        end
    end

    always @(posedge(clk)) begin
        if (dma_write_en) begin
            if (bank_select == 1'b0) begin
                sram_bank0[dma_write_addr]<=dma_write_data;
            end else if (bank_swap) begin
                sram_bank1[dma_write_addr]<=dma_write_data;
            end
        end
    end

endmodule