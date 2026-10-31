`timescale 1ns/1ps
// 64-bit tile-word unpacker and systolic skew network.
// Each input word contains four 16-bit vectors (one per row/column).
// Row r is delayed r accepted advances; column c is delayed c advances.
module systolic_tile_feeder_v2 (
    input wire clk, input wire rst_n, input wire clear, input wire advance,
    input wire [63:0] act_word, input wire act_word_valid, input wire act_word_last,
    input wire [63:0] weight_word, input wire weight_word_valid, input wire weight_word_last,
    output wire input_ready,
    output wire [15:0] act_row_out [0:3], output wire [3:0] act_row_valid,
    output wire [3:0] act_row_last,
    output wire [15:0] weight_col_out [0:3], output wire [3:0] weight_col_valid,
    output wire [3:0] weight_col_last
);
    reg [15:0] ad [0:3][0:2], wd [0:3][0:2];
    reg av [0:3][0:2], wv [0:3][0:2];
    reg al [0:3][0:2], wl [0:3][0:2];
    assign input_ready = advance;
    genvar r,c;
    generate
      for (r=0;r<4;r=r+1) begin: A_SKEW
        if (r==0) begin
          assign act_row_out[r] = clear ? 16'd0 : act_word[16*r +: 16];
          assign act_row_valid[r] = !clear && act_word_valid;
          assign act_row_last[r] = !clear && act_word_last;
        end else begin
          integer ai;
          always @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear) begin
              for (ai=0;ai<3;ai=ai+1) begin ad[r][ai]<=0; av[r][ai]<=0; al[r][ai]<=0; end
            end else if (advance) begin
              ad[r][0] <= act_word[16*r +: 16]; av[r][0] <= act_word_valid; al[r][0] <= act_word_last;
              if (r>1) begin ad[r][1]<=ad[r][0]; av[r][1]<=av[r][0]; al[r][1]<=al[r][0]; end
              if (r>2) begin ad[r][2]<=ad[r][1]; av[r][2]<=av[r][1]; al[r][2]<=al[r][1]; end
            end
          end
          assign act_row_out[r]=ad[r][r-1]; assign act_row_valid[r]=av[r][r-1]; assign act_row_last[r]=al[r][r-1];
        end
      end
      for (c=0;c<4;c=c+1) begin: W_SKEW
        if (c==0) begin
          assign weight_col_out[c]=clear ? 16'd0 : weight_word[16*c +: 16];
          assign weight_col_valid[c]=!clear && weight_word_valid;
          assign weight_col_last[c]=!clear && weight_word_last;
        end else begin
          integer wi;
          always @(posedge clk or negedge rst_n) begin
            if (!rst_n || clear) begin
              for (wi=0;wi<3;wi=wi+1) begin wd[c][wi]<=0; wv[c][wi]<=0; wl[c][wi]<=0; end
            end else if (advance) begin
              wd[c][0] <= weight_word[16*c +: 16]; wv[c][0] <= weight_word_valid; wl[c][0] <= weight_word_last;
              if (c>1) begin wd[c][1]<=wd[c][0]; wv[c][1]<=wv[c][0]; wl[c][1]<=wl[c][0]; end
              if (c>2) begin wd[c][2]<=wd[c][1]; wv[c][2]<=wv[c][1]; wl[c][2]<=wl[c][1]; end
            end
          end
          assign weight_col_out[c]=wd[c][c-1]; assign weight_col_valid[c]=wv[c][c-1]; assign weight_col_last[c]=wl[c][c-1];
        end
      end
    endgenerate
endmodule
