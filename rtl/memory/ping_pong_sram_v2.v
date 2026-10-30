`timescale 1ns/1ps
// Two-bank scratchpad with explicit ownership.
// Compute reads the active bank. DMA writes only the inactive bank.
// dma_commit marks the inactive bank complete; bank_swap_req activates it.
module ping_pong_sram_v2 #(
    parameter integer DATA_WIDTH = 64,
    parameter integer ADDR_WIDTH = 8
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      dma_write_valid,
    output wire                      dma_write_ready,
    input  wire [ADDR_WIDTH-1:0]     dma_write_addr,
    input  wire [DATA_WIDTH-1:0]     dma_write_data,

    input  wire                      dma_commit,
    output wire                      dma_commit_ready,
    output reg                       prefetch_complete,

    input  wire                      bank_swap_req,
    output reg                       bank_swap_ack,
    output reg                       bank_swap_rejected,
    output reg                       active_bank,

    input  wire                      compute_read_en,
    input  wire [ADDR_WIDTH-1:0]     compute_read_addr,
    output reg                       compute_read_valid,
    output reg  [DATA_WIDTH-1:0]     compute_read_data
);
    localparam integer DEPTH = (1 << ADDR_WIDTH);

    reg [DATA_WIDTH-1:0] bank0 [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] bank1 [0:DEPTH-1];

    wire swap_fire = bank_swap_req && prefetch_complete;

    // Do not accept more DMA data after commit, or during a swap request.
    assign dma_write_ready  = !prefetch_complete && !bank_swap_req;
    assign dma_commit_ready = !prefetch_complete && !bank_swap_req;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_bank          <= 1'b0;
            prefetch_complete   <= 1'b0;
            bank_swap_ack        <= 1'b0;
            bank_swap_rejected   <= 1'b0;
            compute_read_valid   <= 1'b0;
            compute_read_data    <= {DATA_WIDTH{1'b0}};
        end else begin
            bank_swap_ack      <= 1'b0;
            bank_swap_rejected <= 1'b0;
            compute_read_valid <= 1'b0;

            // A bank may be activated only after the DMA producer commits it.
            if (bank_swap_req) begin
                if (prefetch_complete) begin
                    active_bank        <= ~active_bank;
                    prefetch_complete <= 1'b0;
                    bank_swap_ack      <= 1'b1;
                end else begin
                    bank_swap_rejected <= 1'b1;
                end
            end else begin
                if (dma_write_valid && dma_write_ready) begin
                    if (active_bank == 1'b0)
                        bank1[dma_write_addr] <= dma_write_data;
                    else
                        bank0[dma_write_addr] <= dma_write_data;
                end

                // Commit is a separate handshake, after the final data beat.
                if (dma_commit && dma_commit_ready)
                    prefetch_complete <= 1'b1;
            end

            // Reads are synchronous (one-cycle response). Suppress a read on
            // the exact edge where ownership changes to avoid ambiguous data.
            if (compute_read_en && !swap_fire) begin
                compute_read_valid <= 1'b1;
                if (active_bank == 1'b0)
                    compute_read_data <= bank0[compute_read_addr];
                else
                    compute_read_data <= bank1[compute_read_addr];
            end
        end
    end
endmodule
