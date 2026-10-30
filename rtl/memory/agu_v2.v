`timescale 1ns/1ps
// 2-D word address generator with a lossless valid/ready interface.
// Address and VALID remain stable until READY is observed.
module agu_v2 #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer WORD_BYTES = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire                  start_valid,
    output wire                  start_ready,
    input  wire [ADDR_WIDTH-1:0] base_addr,
    input  wire [15:0]           rows,
    input  wire [15:0]           words_per_row,
    input  wire [31:0]           row_stride_bytes,

    output reg                   addr_valid,
    input  wire                  addr_ready,
    output reg  [ADDR_WIDTH-1:0] addr,

    output reg                   busy,
    output reg                   done,
    output reg                   error,
    output reg  [2:0]            error_code
);
    localparam [2:0] ERR_NONE      = 3'd0;
    localparam [2:0] ERR_DIMENSION = 3'd1;
    localparam [2:0] ERR_ALIGN     = 3'd2;
    localparam [2:0] ERR_STRIDE    = 3'd3;
    localparam [2:0] ERR_OVERFLOW  = 3'd4;

    localparam [63:0] MAX_ADDR = (64'h1 << ADDR_WIDTH) - 1'b1;

    reg [ADDR_WIDTH-1:0] base_q;
    reg [15:0] rows_q;
    reg [15:0] words_q;
    reg [31:0] stride_q;
    reg [15:0] row_count;
    reg [15:0] col_count;

    wire [63:0] row_span = (rows == 0) ? 64'd0 :
                           ({48'd0, (rows - 16'd1)} * {32'd0, row_stride_bytes});
    wire [63:0] col_span = (words_per_row == 0) ? 64'd0 :
                           ({48'd0, (words_per_row - 16'd1)} * WORD_BYTES);
    wire [63:0] last_addr_wide = {{(64-ADDR_WIDTH){1'b0}}, base_addr} + row_span + col_span;

    assign start_ready = !busy && !addr_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base_q     <= {ADDR_WIDTH{1'b0}};
            rows_q     <= 16'd0;
            words_q    <= 16'd0;
            stride_q   <= 32'd0;
            row_count  <= 16'd0;
            col_count  <= 16'd0;
            addr       <= {ADDR_WIDTH{1'b0}};
            addr_valid <= 1'b0;
            busy       <= 1'b0;
            done       <= 1'b0;
            error      <= 1'b0;
            error_code <= ERR_NONE;
        end else begin
            done  <= 1'b0;
            error <= 1'b0;

            if (start_valid && start_ready) begin
                if ((rows == 0) || (words_per_row == 0)) begin
                    error      <= 1'b1;
                    error_code <= ERR_DIMENSION;
                end else if ((base_addr % WORD_BYTES) != 0) begin
                    error      <= 1'b1;
                    error_code <= ERR_ALIGN;
                end else if ((row_stride_bytes < (words_per_row * WORD_BYTES)) ||
                             ((row_stride_bytes % WORD_BYTES) != 0)) begin
                    error      <= 1'b1;
                    error_code <= ERR_STRIDE;
                end else if (last_addr_wide > MAX_ADDR) begin
                    error      <= 1'b1;
                    error_code <= ERR_OVERFLOW;
                end else begin
                    base_q     <= base_addr;
                    rows_q     <= rows;
                    words_q    <= words_per_row;
                    stride_q   <= row_stride_bytes;
                    row_count  <= 16'd0;
                    col_count  <= 16'd0;
                    addr       <= base_addr;
                    addr_valid <= 1'b1;
                    busy       <= 1'b1;
                    error_code <= ERR_NONE;
                end
            end else if (busy && addr_valid && addr_ready) begin
                if ((col_count + 16'd1) < words_q) begin
                    col_count <= col_count + 16'd1;
                    addr      <= addr + WORD_BYTES;
                end else begin
                    col_count <= 16'd0;
                    if ((row_count + 16'd1) < rows_q) begin
                        row_count <= row_count + 16'd1;
                        addr <= base_q + ((row_count + 16'd1) * stride_q);
                    end else begin
                        addr_valid <= 1'b0;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
