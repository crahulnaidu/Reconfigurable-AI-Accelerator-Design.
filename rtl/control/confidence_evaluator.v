module confidence_evaluator (
    input  wire        clk,
    input  wire        rst_n,

    // Control Signals from Sequencer FSM
    input  wire        eval_start,       // Pulse high to clear max registers before new pass
    input  wire        eval_enable,      // Asserted while streaming logit/activation outputs
    input  wire [15:0] activation_in,    // Output logit/activation scalar from post-processor
    input  wire [15:0] conf_thresh,      // Per-layer threshold target from descriptor frame

    // Evaluator Outputs
    output reg  [15:0] conf_score,       // Computed margin score A(k) = Max_1 - Max_2
    output reg         early_exit_trigger// Asserts high if conf_score >= conf_thresh
);

    reg signed [15:0] max_1;
    reg signed [15:0] max_2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_1              <= 16'sh8000; // Smallest signed 16-bit integer (-32768)
            max_2              <= 16'sh8000;
            conf_score         <= 16'h0000;
            early_exit_trigger <= 1'b0;
        end else if (eval_start) begin
            max_1              <= 16'sh8000;
            max_2              <= 16'sh8000;
            conf_score         <= 16'h0000;
            early_exit_trigger <= 1'b0;
        end else if (eval_enable) begin
            // Top-2 Max tracking logic
            if ($signed(activation_in) > max_1) begin
                max_2 <= max_1;
                max_1 <= $signed(activation_in);
            end else if ($signed(activation_in) > max_2) begin
                max_2 <= $signed(activation_in);
            end

            // Compute confidence score margin A(k)
            if (max_1 > max_2) begin
                conf_score <= max_1 - max_2;
            end else begin
                conf_score <= 16'h0000;
            end

            // Evaluate threshold
            if ((max_1 - max_2) >= conf_thresh) begin
                early_exit_trigger <= 1'b1;
            end else begin
                early_exit_trigger <= 1'b0;
            end
        end
    end

endmodule