`timescale 1ns/1ps
// Reduces the SIMD partial-K lanes to one scalar output per PE, then requantizes.
// INT8: sum two signed 32-bit lane accumulators.
// INT4: sum four signed 32-bit lane accumulators.
// y = clamp((lane_sum * scale_m0) >>> shift_n + signed_zero_point).
module post_processor_mesh_v2 (
    input wire clk, input wire rst_n, input wire clear,
    input wire [1:0] precision_mode,
    input wire [31:0] scale_m0, input wire [4:0] shift_n, input wire [7:0] zero_point_z,
    input wire [127:0] pe_accum_in [0:3][0:3], input wire [15:0] pe_result_valid,
    input wire [15:0] result_ready,
    output reg [15:0] result_valid, output reg [15:0] result_data [0:3][0:3],
    output reg tile_done, output reg [31:0] saturation_count
);
    function signed [65:0] requantize;
      input signed [33:0] s; input signed [31:0] m; input [4:0] sh; input signed [7:0] z;
      reg signed [65:0] p;
      reg signed [65:0] s_ext, m_ext;
      begin s_ext={{32{s[33]}},s}; m_ext={{34{m[31]}},m}; p=s_ext*m_ext; requantize=(p>>>sh)+$signed({{58{z[7]}},z}); end
    endfunction
    function [7:0] clamp8;
      input signed [65:0] q;
      begin if(q>66'sd127) clamp8=8'h7f; else if(q< -66'sd128) clamp8=8'h80; else clamp8=q[7:0]; end
    endfunction
    function [3:0] clamp4;
      input signed [65:0] q;
      begin if(q>66'sd7) clamp4=4'h7; else if(q< -66'sd8) clamp4=4'h8; else clamp4=q[3:0]; end
    endfunction
    function sat8;
      input signed [65:0] q; begin sat8=(q>66'sd127)||(q< -66'sd128); end
    endfunction
    function sat4;
      input signed [65:0] q; begin sat4=(q>66'sd7)||(q< -66'sd8); end
    endfunction

    wire [15:0] capture_fire, seen_next;
    wire [2:0] sat_per_pe [0:15];
    reg [15:0] seen;
    reg [31:0] sat_increment;
    integer i;
    genvar r,c;
    generate
      for(r=0;r<4;r=r+1) begin: PP_R
        for(c=0;c<4;c=c+1) begin: PP_C
          localparam integer IDX=r*4+c;
          wire signed [33:0] lane0_ext = {{2{pe_accum_in[r][c][31]}}, pe_accum_in[r][c][31:0]};
          wire signed [33:0] lane1_ext = {{2{pe_accum_in[r][c][63]}}, pe_accum_in[r][c][63:32]};
          wire signed [33:0] lane2_ext = {{2{pe_accum_in[r][c][95]}}, pe_accum_in[r][c][95:64]};
          wire signed [33:0] lane3_ext = {{2{pe_accum_in[r][c][127]}}, pe_accum_in[r][c][127:96]};
          wire signed [33:0] lane_sum;
          wire signed [65:0] q;
          wire [7:0] v8;
          wire [3:0] v4;
          wire sat;
          // Extend each lane before addition so the reduction itself cannot
          // overflow at 32 bits before reaching the 34-bit lane_sum.
          assign lane_sum = (precision_mode==2'b01) ?
            (lane0_ext + lane1_ext) :
            (lane0_ext + lane1_ext + lane2_ext + lane3_ext);
          assign q=requantize(lane_sum,$signed(scale_m0),shift_n,$signed(zero_point_z));
          assign v8=clamp8(q); assign v4=clamp4(q);
          assign sat=(precision_mode==2'b01)?sat8(q):sat4(q);
          assign sat_per_pe[IDX]=sat?3'd1:3'd0;
          assign capture_fire[IDX]=pe_result_valid[IDX] && (!result_valid[IDX] || result_ready[IDX]);
          assign seen_next[IDX]=seen[IDX] || capture_fire[IDX];
          always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin result_valid[IDX]<=1'b0; result_data[r][c]<=16'd0; end
            else if(clear) begin result_valid[IDX]<=1'b0; result_data[r][c]<=16'd0; end
            else if(capture_fire[IDX]) begin
              // Expose each scalar result as a signed 16-bit value.
              result_data[r][c] <= (precision_mode==2'b01)?
                                   {{8{v8[7]}},v8}:{{12{v4[3]}},v4};
              result_valid[IDX] <= 1'b1;
            end else if(result_valid[IDX] && result_ready[IDX]) result_valid[IDX]<=1'b0;
          end
        end
      end
    endgenerate
    always @* begin
      sat_increment=0;
      for(i=0;i<16;i=i+1) if(capture_fire[i]) sat_increment=sat_increment+sat_per_pe[i];
    end
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin seen<=0; tile_done<=0; saturation_count<=0; end
      else if(clear) begin seen<=0; tile_done<=0; saturation_count<=0; end
      else begin
        seen<=seen_next;
        saturation_count<=saturation_count+sat_increment;
        if(&seen_next) tile_done<=1'b1;
      end
    end
endmodule
