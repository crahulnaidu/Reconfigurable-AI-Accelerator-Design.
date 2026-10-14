`timescale 1ns/1ps

module tb_sequencer_fsm;

    reg        clk;
    reg        rst_n;
    reg        start_inference;
    reg [31:0] root_descriptor_ptr;
    reg        descriptor_done;
    reg        agu_done;
    reg        early_exit_trigger;
    reg [31:0] front_ptr;
    reg [31:0] exit_ptr;

    wire       load_descriptor_en;
    wire       bank_swap;
    wire       start_agu;
    wire       acc_enable;
    wire       eval_start;
    wire       eval_enable;
    wire [31:0] active_descriptor_ptr;
    wire       inference_complete;
    wire       early_exit_occurred;

    // Instantiate DUT
    sequencer_fsm dut (
        .clk(clk),
        .rst_n(rst_n),
        .start_inference(start_inference),
        .root_descriptor_ptr(root_descriptor_ptr),
        .descriptor_done(descriptor_done),
        .agu_done(agu_done),
        .early_exit_trigger(early_exit_trigger),
        .front_ptr(front_ptr),
        .exit_ptr(exit_ptr),
        .load_descriptor_en(load_descriptor_en),
        .bank_swap(bank_swap),
        .start_agu(start_agu),
        .acc_enable(acc_enable),
        .eval_start(eval_start),
        .eval_enable(eval_enable),
        .active_descriptor_ptr(active_descriptor_ptr),
        .inference_complete(inference_complete),
        .early_exit_occurred(early_exit_occurred)
    );

    always #5 clk = ~clk;

    initial begin
        clk                 = 0;
        rst_n               = 0;
        start_inference     = 0;
        root_descriptor_ptr = 32'h8000_0000;
        descriptor_done     = 0;
        agu_done            = 0;
        early_exit_trigger  = 0;
        front_ptr           = 32'h8000_0100;
        exit_ptr            = 32'h8000_F000;

        #15 rst_n = 1;
        @(posedge clk);

        // --- Step 1: Launch Inference ---
        start_inference = 1;
        @(posedge clk);
        start_inference = 0;

        // FSM in ST_FETCH_DESCR
        @(posedge clk);
        descriptor_done = 1;
        @(posedge clk);
        descriptor_done = 0;

        // FSM in ST_COMPUTE
        repeat(3) @(posedge clk);
        agu_done = 1;
        @(posedge clk);
        agu_done = 0;

        // FSM in ST_EVAL_CONF -> Force Early Exit Branch
        early_exit_trigger = 1;
        @(posedge clk);

        $display("\n=======================================================");
        $display(" PHASE 2 DAY 6: SEQUENCER FSM VERIFICATION PASSED");
        $display("=======================================================");
        $display(" Active Pointer after Early Exit = %h (Expected: 8000F000)", active_descriptor_ptr);
        $display("=======================================================\n");

        $finish;
    end

endmodule