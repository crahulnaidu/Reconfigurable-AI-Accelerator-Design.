module sequencer_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // Host System Control Signals
    input  wire        start_inference,         // Pulse high to launch network execution
    input  wire [31:0] root_descriptor_ptr,     // DRAM address of the 1st layer descriptor

    // Handshaking Inputs from Sub-Modules
    input  wire        descriptor_done,         // Asserted when descriptor parser finishes
    input  wire        agu_done,                // Asserted when AGU finishes tensor stream
    input  wire        early_exit_trigger,      // Asserted by confidence_evaluator if threshold met

    // Pointer Addresses from Descriptor Engine
    input  wire [31:0] front_ptr,               // Address of next sequential layer
    input  wire [31:0] exit_ptr,                // Address of early exit head descriptor

    // Sub-Module Control Pulse Outputs
    output reg         load_descriptor_en,      // Triggers descriptor_engine fetch
    output reg         bank_swap,               // Toggles Ping-Pong SRAM buffers
    output reg         start_agu,               // Triggers address generation for compute
    output reg         acc_enable,              // Enables Systolic Array execution
    output reg         eval_start,              // Resets confidence_evaluator top-2 registers
    output reg         eval_enable,             // Enables confidence_evaluator pass

    // Status Outputs
    output reg  [31:0] active_descriptor_ptr,   // Current descriptor address being processed
    output reg         inference_complete,      // Asserts high when execution halts or exits early
    output reg         early_exit_occurred      // High if execution finished via an early exit
);

    // FSM State Encoding
    localparam [2:0] ST_IDLE         = 3'b000;
    localparam [2:0] ST_FETCH_DESCR  = 3'b001;
    localparam [2:0] ST_CONFIG_LAYER = 3'b010;
    localparam [2:0] ST_COMPUTE      = 3'b011;
    localparam [2:0] ST_EVAL_CONF    = 3'b100;
    localparam [2:0] ST_NEXT_LAYER   = 3'b101;
    localparam [2:0] ST_EARLY_EXIT   = 3'b110;

    reg [2:0] current_state, next_state;

    // State Register & Active Descriptor Pointer Tracking
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_state         <= ST_IDLE;
            active_descriptor_ptr <= 32'h0000_0000;
        end else begin
            current_state <= next_state;
            if (current_state == ST_IDLE && start_inference) begin
                active_descriptor_ptr <= root_descriptor_ptr;
            end else if (current_state == ST_NEXT_LAYER) begin
                active_descriptor_ptr <= front_ptr;
            end else if (current_state == ST_EARLY_EXIT) begin
                active_descriptor_ptr <= exit_ptr;
            end
        end
    end

    // Next-State & Output Combinational Logic
    always @(*) begin
        // Default Output State
        load_descriptor_en  = 1'b0;
        bank_swap           = 1'b0;
        start_agu           = 1'b0;
        acc_enable          = 1'b0;
        eval_start          = 1'b0;
        eval_enable         = 1'b0;
        inference_complete  = 1'b0;
        early_exit_occurred = 1'b0;
        next_state          = current_state;

        case (current_state)
            ST_IDLE: begin
                if (start_inference) begin
                    next_state = ST_FETCH_DESCR;
                end
            end

            ST_FETCH_DESCR: begin
                load_descriptor_en = 1'b1;
                if (descriptor_done) begin
                    next_state = ST_CONFIG_LAYER;
                end
            end

            ST_CONFIG_LAYER: begin
                bank_swap  = 1'b1; // Rotate Ping-Pong buffer for active layer
                eval_start = 1'b1; // Clear confidence score registers
                start_agu  = 1'b1; // Kick off address generation stream
                next_state = ST_COMPUTE;
            end

            ST_COMPUTE: begin
                acc_enable  = 1'b1;
                eval_enable = 1'b1;
                if (agu_done) begin
                    next_state = ST_EVAL_CONF;
                end
            end

            ST_EVAL_CONF: begin
                if (early_exit_trigger) begin
                    if (exit_ptr != 32'h0000_0000) begin
                        next_state = ST_EARLY_EXIT;
                    end else begin
                        // Terminal Exit Head
                        inference_complete  = 1'b1;
                        early_exit_occurred = 1'b1;
                        next_state          = ST_IDLE;
                    end
                end else if (front_ptr == 32'h0000_0000) begin
                    // Final Layer Reached (End of Network)
                    inference_complete = 1'b1;
                    next_state         = ST_IDLE;
                end else begin
                    next_state = ST_NEXT_LAYER;
                end
            end

            ST_NEXT_LAYER: begin
                next_state = ST_FETCH_DESCR;
            end

            ST_EARLY_EXIT: begin
                early_exit_occurred = 1'b1;
                next_state          = ST_FETCH_DESCR;
            end

            default: next_state = ST_IDLE;
        endcase
    end

endmodule