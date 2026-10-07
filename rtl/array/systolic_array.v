module systolic_array(
    input wire clk,
    input wire rst_n,

    input wire [1:0] precision_mode,
    input wire acc_clear,
    input wire acc_enable,

    input wire [31:0] scale_m0,
    input wire [4:0] shift_n,
    input wire [7:0] zero_point_z,

    input wire [15:0] act_row_in [0:3],
    input wire [15:0] weight_col_in[0:3],

    output wire [15:0] array_data_out[0:3][0:3],

    output reg [19:0] total_zero_skips
);

   wire [15:0] act_wire [0:3][0:4];
   wire [15:0] pe_skips [0:3][0:3];

   genvar r,c;
   generate 
       for (r=0; r<4; r=r+1) begin : gen_rows
            assign act_wire[r][0] = act_row_in[r];

            for (c=0; c<4; c=c+1) begin : gen_cols
                 pe_top pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .precision_mode(precision_mode),
                    .acc_clear(acc_clear),
                    .acc_enable(acc_enable),
                    .operand_a(act_wire[r][c]),
                    .operand_b(weight_col_in[c]),
                    .scale_m0(scale_m0),
                    .shift_n(shift_n),
                    .zero_point_z(zero_point_z),
                    .pe_data_out(array_data_out[r][c]),
                    .zero_skip_count(pe_skips[r][c])
                 );

                 assign act_wire[r][c+1]=act_wire[r][c];
            end
       end
   endgenerate

   integer i,j;
   always @(*) begin
    total_zero_skips=20'h00000;
    for (i=0; i<4; i=i+1) begin
        for (j=0; j<4; j=j+1) begin
            total_zero_skips=total_zero_skips+pe_skips[i][j];
        end
    end
   end
endmodule