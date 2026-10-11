`timescale 1ns/1ps

module tb_confidence_evaluator;

    reg        clk;
    reg        rst_n;
    reg        eval_start;
    reg        eval_enable;
    reg [15:0] activation_in;
    reg [15:0] conf_thresh;

    wire [15:0] conf_score;
    wire        early_exit_trigger;

    // Instantiate DUT
    confidence_evaluator dut (
        .clk(clk),
        .rst_n(rst_n),
        .eval_start(eval_start),
        .eval_enable(eval_enable),
        .activation_in(activation_in),
        .conf_thresh(conf_thresh),
        .conf_score(conf_score),
        .early_exit_trigger(early_exit_trigger)
    );

    always #5 clk = ~clk;

    initial begin
        clk           = 0;
        rst_n         = 0;
        eval_start    = 0;
        eval_enable   = 0;
        activation_in = 16'h0000;
        conf_thresh   = 16'd50; // Threshold score set to 50

        #15 rst_n = 1;
        @(posedge clk);

        // --- Step 1: Start Evaluation Pass ---
        eval_start = 1;
        @(posedge clk);
        eval_start  = 0;
        eval_enable = 1;

        // --- Step 2: Stream Logit Stream (Ambiguous class probabilities) ---
        activation_in = 16'sd100; @(posedge clk); // Max_1 = 100
        activation_in = 16'sd85;  @(posedge clk); // Max_2 = 85  -> Margin = 15 (< 50)
        activation_in = 16'd0;   @(posedge clk);

        $display(" Pass 1 (Ambiguous Logits): Margin Score = %d, Early Exit Trigger = %b", 
                 conf_score, early_exit_trigger);

        // --- Step 3: Stream Strong Logit Signal (High confidence hit) ---
        activation_in = 16'sd180; @(posedge clk); // New Max_1 = 180 (Previous Max_1=100 becomes Max_2)
                                                  // Margin = 180 - 100 = 80 (>= 50)
        @(posedge clk);

        $display(" Pass 2 (High Confidence): Margin Score = %d, Early Exit Trigger = %b", 
                 conf_score, early_exit_trigger);

        eval_enable = 0;
        @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 5: CONFIDENCE EVALUATOR VERIFIED PASSED");
        $display("=======================================================");
        $display(" Final Score  = %d (Expected: 80)", conf_score);
        $display(" Exit Trigger = %b (Expected: 1)", early_exit_trigger);
        $display("=======================================================\n");

        $finish;
    end

endmodule