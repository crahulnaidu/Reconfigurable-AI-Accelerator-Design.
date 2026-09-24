module post_processor (
    input  wire [1:0]  precision_mode, // 2'b00: FP16, 2'b01: INT8, 2'b10: INT4
    input  wire [31:0] accum_in,       // Raw 32-bit partial sum from PE accumulator
    
    // Per-Layer Post-Processing Descriptor Parameters
    input  wire [31:0] scale_m0,       // 32-bit fixed-point multiplier M_0
    input  wire [4:0]  shift_n,        // Right-shift count n
    input  wire [7:0]  zero_point_z,   // Signed zero-point offset Z
    
    output reg  [15:0] post_proc_out   // Scaled & clamped output tensor
);

    // =========================================================================
    // 1. Fixed-Point Multiplier (32-bit Accumulator x 32-bit M_0)
    // =========================================================================
    wire signed [63:0] scaled_product;
    assign scaled_product = $signed(accum_in) * $signed(scale_m0);

    // =========================================================================
    // 2. Arithmetic Bit-Shifter & Zero-Point Adder
    // =========================================================================
    wire signed [63:0] shifted_val;
    assign shifted_val = scaled_product >>> shift_n;

    wire signed [31:0] aligned_val;
    assign aligned_val = shifted_val[31:0] + $signed({{24{zero_point_z[7]}}, zero_point_z});

    // =========================================================================
    // 3. Saturating Clamping Logic (INT8 & INT4 Limits)
    // =========================================================================
    reg signed [7:0] int8_clamped;
    reg signed [3:0] int4_clamped;

    always @(*) begin
        // INT8 Clamping Bounds [-128 to +127]
        if (aligned_val > 32'sd127) begin
            int8_clamped = 8'sd127;
        end else if (aligned_val < -32'sd128) begin
            int8_clamped = -8'sd128;
        end else begin
            int8_clamped = aligned_val[7:0];
        end

        // INT4 Clamping Bounds [-8 to +7]
        if (aligned_val > 32'sd7) begin
            int4_clamped = 4'sd7;
        end else if (aligned_val < -32'sd8) begin
            int4_clamped = -8'sd8;
        end else begin
            int4_clamped = aligned_val[3:0];
        end
    end

    // =========================================================================
    // 4. Output Multiplexing Based on Active Precision
    // =========================================================================
    always @(*) begin
        case (precision_mode)
            2'b00: begin // FP16 Bypass Mode
                post_proc_out = accum_in[15:0];
            end

            2'b01: begin // INT8 Mode (Output sign-extended in lower 8 bits)
                post_proc_out = {{8{int8_clamped[7]}}, int8_clamped};
            end

            2'b10: begin // INT4 Mode (Output packed in lower 4 bits)
                post_proc_out = {{12{int4_clamped[3]}}, int4_clamped};
            end

            default: post_proc_out = 16'h0000;
        endcase
    end

endmodule