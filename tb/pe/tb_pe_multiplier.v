module testbench;

reg  [1:0] precision_mode;
reg [15:0] operand_a;
reg [15:0] operand_b;
wire [31:0] product_out;

pe_multiplier uut(
    .precision_mode(precision_mode),
    .operand_a(operand_a),
    .operand_b(operand_b),
    .product_out(product_out)
);

initial begin
    $monitor("Time=%0t,precision=%d,product=%d",$time,precision_mode,product_out);

    operand_a=16'h1111;
    operand_b=16'h1010;

    precision_mode=2'b00;

    #10;

    precision_mode=2'b01;

    #10;

    precision_mode=2'b10;

    #10;
end
endmodule