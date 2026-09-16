module mult8_sig(
    input  signed [7:0] a_in,
    input  signed [7:0] b_in,
    output  signed [15:0] c_out
);

assign c_out=a_in * b_in;
endmodule