module processing_element (
    input  wire        clk,
    input  wire        rst_n,
    
    // Control & Configuration Signals
    input  wire [1:0]  precision_mode,   // 2'b00: FP16, 2'b01: INT8 SIMD, 2'b10: INT4 SIMD
    input  wire        acc_clear,        // Resets accumulators to 0
    input  wire        acc_enable,       // Enable accumulation pass
    
    // Data Inputs
    input  wire [15:0] operand_a,        // Activation vector/scalar
    input  wire [15:0] operand_b,        // Weight vector/scalar
    
    // Outputs
    output reg  [31:0] accum_out,        // 32-bit packed accumulator state
    output reg  [15:0] zero_skip_count   // Hardware telemetry: sparsity zero skips
);

    // =========================================================================
    // 1. Sparsity Zero-Detector & Clock Gating Signal
    // =========================================================================
    wire is_zero_a = (operand_a == 16'h0000);
    wire is_zero_b = (operand_b == 16'h0000);
    wire pe_zero_bypass = is_zero_a || is_zero_b;

    // =========================================================================
    // 2. Instantiate Day 1 SIMD Multiplier
    // =========================================================================
    wire [31:0] mult_product;
    
    pe_multiplier multiplier_inst (
        .precision_mode(precision_mode),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .product_out(mult_product)
    );

    // =========================================================================
    // 3. Reconfigurable SIMD Accumulation Logic
    // =========================================================================
    
    // INT4 Accumulation Channels (Four 8-bit accumulators)
    wire signed [7:0] int4_p0 = mult_product[7:0];
    wire signed [7:0] int4_p1 = mult_product[15:8];
    wire signed [7:0] int4_p2 = mult_product[23:16];
    wire signed [7:0] int4_p3 = mult_product[31:24];

    wire signed [7:0] int4_acc0 = accum_out[7:0]   + int4_p0;
    wire signed [7:0] int4_acc1 = accum_out[15:8]  + int4_p1;
    wire signed [7:0] int4_acc2 = accum_out[23:16] + int4_p2;
    wire signed [7:0] int4_acc3 = accum_out[31:24] + int4_p3;

    // INT8 Accumulation Channels (Two 16-bit accumulators)
    wire signed [15:0] int8_p0 = mult_product[15:0];
    wire signed [15:0] int8_p1 = mult_product[31:16];

    wire signed [15:0] int8_acc0 = accum_out[15:0]  + int8_p0;
    wire signed [15:0] int8_acc1 = accum_out[31:16] + int8_p1;

    // FP16 / Full Width Accumulation Channel (32-bit accumulator)
    wire signed [31:0] fp16_acc = accum_out + mult_product;

    // =========================================================================
    // 4. Sequential Accumulator & Telemetry Register Update
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accum_out       <= 32'h0000_0000;
            zero_skip_count <= 16'h0000;
        end else if (acc_clear) begin
            accum_out       <= 32'h0000_0000;
        end else if (acc_enable) begin
            if (pe_zero_bypass) begin
                // Zero-Bypass: Skip multiplier accumulation & increment telemetry counter
                zero_skip_count <= zero_skip_count + 1'b1;
            end else begin
                // Update accumulator based on current precision_mode
                case (precision_mode)
                    2'b00: begin // FP16 / 32-bit Accumulation Mode
                        accum_out <= fp16_acc;
                    end
                    2'b01: begin // INT8 SIMD Mode (Two 16-bit accumulators)
                        accum_out <= {int8_acc1, int8_acc0};
                    end
                    2'b10: begin // INT4 SIMD Mode (Four 8-bit accumulators)
                        accum_out <= {int4_acc3, int4_acc2, int4_acc1, int4_acc0};
                    end
                    default: accum_out <= 32'h0000_0000;
                endcase
            end
        end
    end

endmodule