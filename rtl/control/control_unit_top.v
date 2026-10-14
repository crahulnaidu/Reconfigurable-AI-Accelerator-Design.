module control_unit_top (
    input  wire        clk,
    input  wire        rst_n,

    // Host Controls
    input  wire        start_inference,         // Pulse high to launch inference
    input  wire [31:0] root_descriptor_ptr,     // Address of 1st layer descriptor

    // Memory Bus Inputs (Descriptor Fetch & Feature Stream)
    input  wire [31:0] descriptor_word_in,     // Streamed 32-bit descriptor data
    input  wire [2:0]  word_index,              // Index (0 to 5) of descriptor word
    input  wire        descriptor_done,         // Asserted when descriptor parse completes
    input  wire [15:0] activation_in,           // Intermediate logit output from post-processor

    // Tensor Dimensions (Passed from Active Descriptor Frame)
    input  wire [15:0] tensor_height,
    input  wire [15:0] tensor_width,
    input  wire [15:0] stride_bytes,

    // System Control & Memory Outputs
    output wire [31:0] active_mem_addr,         // Address driven to SRAM/DRAM
    output wire        bank_swap,               // Toggles Ping-Pong SRAM buffers
    output wire        acc_enable,              // Enables Systolic Array execution
    
    // Config Outputs to Systolic Array & Post-Processor
    output wire [1:0]  precision_mode,
    output wire [31:0] scale_m0,
    output wire [4:0]  shift_n,
    output wire [7:0]  zero_point_z,

    // Status Signals
    output wire        inference_complete,
    output wire        early_exit_occurred
);

    // Internal Wires
    wire [31:0] start_ptr;
    wire [31:0] front_ptr;
    wire [31:0] exit_ptr;
    wire [15:0] conf_thresh;
    wire [15:0] conf_score;

    wire        load_descriptor_en;
    wire        start_agu;
    wire        eval_start;
    wire        eval_enable;
    wire        agu_done;
    wire        early_exit_trigger;
    wire [31:0] active_descriptor_ptr;

    // 1. Instantiate Linked Layer Descriptor Engine
    descriptor_engine desc_eng_inst (
        .clk(clk),
        .rst_n(rst_n),
        .load_descriptor_en(load_descriptor_en),
        .descriptor_word_in(descriptor_word_in),
        .word_index(word_index),
        .start_ptr(start_ptr),
        .front_ptr(front_ptr),
        .exit_ptr(exit_ptr),
        .precision_mode(precision_mode),
        .scale_m0(scale_m0),
        .shift_n(shift_n),
        .zero_point_z(zero_point_z),
        .conf_thresh(conf_thresh)
    );

    // 2. Instantiate Address Generation Unit (AGU)
    agu agu_inst (
        .clk(clk),
        .rst_n(rst_n),
        .start_agu(start_agu),
        .start_ptr(start_ptr),
        .tensor_height(tensor_height),
        .tensor_width(tensor_width),
        .stride_bytes(stride_bytes),
        .mem_addr(active_mem_addr),
        .agu_valid(),
        .agu_done(agu_done)
    );

    // 3. Instantiate Hardware Confidence Evaluator
    confidence_evaluator conf_eval_inst (
        .clk(clk),
        .rst_n(rst_n),
        .eval_start(eval_start),
        .eval_enable(eval_enable),
        .activation_in(activation_in),
        .conf_thresh(conf_thresh),
        .conf_score(conf_score),
        .early_exit_trigger(early_exit_trigger)
    );

    // 4. Instantiate Master Execution Sequencer FSM
    sequencer_fsm fsm_inst (
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

endmodule