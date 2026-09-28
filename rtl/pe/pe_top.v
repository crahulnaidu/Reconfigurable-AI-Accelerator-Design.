module pe_top (
    input  wire        clk,
    input  wire        rst_n,

    // Control & Precision Configuration Signals
    input  wire [1:0]  precision_mode,   // 2'b00: FP16, 2'b01: INT8, 2'b10: INT4
    input  wire        acc_clear,        // Clears accumulators for new dot product
    input  wire        acc_enable,       // Enables accumulation pass

    // Data Inputs
    input  wire [15:0] operand_a,        // Activation vector/scalar
    input  wire [15:0] operand_b,        // Weight vector/scalar

    // Layer Descriptor Scaling Parameters (Post-Processor)
    input  wire [31:0] scale_m0,         // Fixed-point scale multiplier M_0
    input  wire [4:0]  shift_n,          // Right-shift count n
    input  wire [7:0]  zero_point_z,     // Signed zero-point offset Z

    // Outputs
    output reg  [15:0] pe_data_out,      // Final scaled & clamped output tensor
    output wire [15:0] zero_skip_count   // Telemetry counter: sparsity zero skips
);

    // =========================================================================
    // 1. Internal Wires
    // =========================================================================
    wire [31:0] raw_accum_out;
    wire [15:0] scaled_post_proc_out;

    // =========================================================================
    // 2. Instantiate Processing Element (Multiplier + Accumulators + Sparsity)
    // =========================================================================
    processing_element pe_core_inst (
        .clk(clk),
        .rst_n(rst_n),
        .precision_mode(precision_mode),
        .acc_clear(acc_clear),
        .acc_enable(acc_enable),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .accum_out(raw_accum_out),
        .zero_skip_count(zero_skip_count)
    );

    // =========================================================================
    // 3. Instantiate Adaptive Post-Processor Unit
    // =========================================================================
    post_processor post_proc_inst (
        .precision_mode(precision_mode),
        .accum_in(raw_accum_out),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .post_proc_out(scaled_post_proc_out)
    );

    // =========================================================================
    // 4. Output Register Stage (Pipelining for Timing Closure)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_data_out <= 16'h0000;
        end else begin
            pe_data_out <= scaled_post_proc_out;
        end
    end

endmodule