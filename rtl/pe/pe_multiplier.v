module pe_multiplier (
    input  wire [1:0]  precision_mode, // 2'b00: FP16, 2'b01: INT8 SIMD, 2'b10: INT4 SIMD
    input  wire [15:0] operand_a,      // Packed input activation(s)
    input  wire [15:0] operand_b,      // Packed input weight(s)
    output reg  [31:0] product_out     // Reconfigurable product output
);

    // =========================================================================
    // 1. INT4 Sub-Byte Unpacking & Sign Extension (4 Parallel Lanes)
    // =========================================================================
    wire signed [7:0] int4_a [0:3];
    wire signed [7:0] int4_b [0:3];
    wire signed [15:0] int4_prod [0:3];

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_int4_lanes
            // Sign-extend 4-bit signed nibbles to 8-bit for clean multiplication
            assign int4_a[i] = {{4{operand_a[i*4 + 3]}}, operand_a[i*4 +: 4]};
            assign int4_b[i] = {{4{operand_b[i*4 + 3]}}, operand_b[i*4 +: 4]};
            assign int4_prod[i] = int4_a[i] * int4_b[i];
        end
    endgenerate

    // =========================================================================
    // 2. INT8 Unpacking & Multiplication (2 Parallel Lanes)
    // =========================================================================
    wire signed [7:0]  int8_a0 = operand_a[7:0];
    wire signed [7:0]  int8_a1 = operand_a[15:8];
    wire signed [7:0]  int8_b0 = operand_b[7:0];
    wire signed [7:0]  int8_b1 = operand_b[15:8];

    wire signed [15:0] int8_prod0 = int8_a0 * int8_b0;
    wire signed [15:0] int8_prod1 = int8_a1 * int8_b1;

    // =========================================================================
    // 3. FP16 Datapath (1 Sign bit, 5 Exponent bits, 10 Mantissa bits)
    // =========================================================================
    wire        fp16_sign_a = operand_a[15];
    wire [4:0]  fp16_exp_a  = operand_a[14:10];
    wire [10:0] fp16_man_a  = {1'b1, operand_a[9:0]}; // Implicit leading 1

    wire        fp16_sign_b = operand_b[15];
    wire [4:0]  fp16_exp_b  = operand_b[14:10];
    wire [10:0] fp16_man_b  = {1'b1, operand_b[9:0]}; // Implicit leading 1

    wire        fp16_sign_out = fp16_sign_a ^ fp16_sign_b;
    wire [5:0]  fp16_exp_sum  = fp16_exp_a + fp16_exp_b - 6'd15; // Subtract Bias (15)
    wire [21:0] fp16_man_prod = fp16_man_a * fp16_man_b;

    // Pack into standard 16-bit FP16 representation
    wire [15:0] fp16_result = {fp16_sign_out, fp16_exp_sum[4:0], fp16_man_prod[20:11]};

    // =========================================================================
    // 4. Output Multiplexing Based on Active Layer Precision Mode
    // =========================================================================
    always @(*) begin
        case (precision_mode)
            2'b00: begin // FP16 Mode (Output zero-extended in upper 16 bits)
                product_out = {16'h0000, fp16_result};
            end

            2'b01: begin // INT8 SIMD Mode (Two 16-bit products packed into 32-bit output)
                product_out = {int8_prod1, int8_prod0};
            end

            2'b10: begin // INT4 SIMD Mode (Four 8-bit products packed into 32-bit output)
                product_out = {int4_prod[3][7:0], int4_prod[2][7:0], 
                               int4_prod[1][7:0], int4_prod[0][7:0]};
            end

            default: product_out = 32'h0000_0000;
        endcase
    end

endmodule