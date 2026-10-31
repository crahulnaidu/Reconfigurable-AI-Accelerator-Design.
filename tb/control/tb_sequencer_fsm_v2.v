`timescale 1ns/1ps

module tb_sequencer_fsm_v2;
    reg clk, rst_n;
    reg start_inference;
    reg [63:0] root_descriptor_ptr;

    wire descriptor_fetch_start;
    wire [63:0] active_descriptor_ptr;
    reg descriptor_done, descriptor_valid, config_error;
    reg [7:0] descriptor_error_code;
    reg [63:0] next_descriptor_ptr, exit_descriptor_ptr;
    reg [5:0] cfg_flags;

    wire layer_start;
    reg compute_done;
    wire confidence_eval_start;
    reg confidence_done, early_exit_trigger, global_early_exit_enable;
    wire output_write_start;
    reg writeback_done;
    reg engine_error;
    reg [7:0] engine_error_code;

    wire busy, inference_complete, early_exit_occurred, error;
    wire [7:0] error_code;

    integer checks;

    sequencer_fsm_v2 dut (
        .clk(clk), .rst_n(rst_n),
        .start_inference(start_inference),
        .root_descriptor_ptr(root_descriptor_ptr),
        .descriptor_fetch_start(descriptor_fetch_start),
        .active_descriptor_ptr(active_descriptor_ptr),
        .descriptor_done(descriptor_done),
        .descriptor_valid(descriptor_valid),
        .config_error(config_error),
        .descriptor_error_code(descriptor_error_code),
        .next_descriptor_ptr(next_descriptor_ptr),
        .exit_descriptor_ptr(exit_descriptor_ptr),
        .cfg_flags(cfg_flags),
        .layer_start(layer_start),
        .compute_done(compute_done),
        .confidence_eval_start(confidence_eval_start),
        .confidence_done(confidence_done),
        .early_exit_trigger(early_exit_trigger),
        .global_early_exit_enable(global_early_exit_enable),
        .output_write_start(output_write_start),
        .writeback_done(writeback_done),
        .engine_error(engine_error),
        .engine_error_code(engine_error_code),
        .busy(busy), .inference_complete(inference_complete),
        .early_exit_occurred(early_exit_occurred),
        .error(error), .error_code(error_code)
    );

    always #5 clk = ~clk;

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("FAIL: %0s", message);
                $fatal(1, "Sequencer assertion failed");
            end else begin
                $display("PASS: %0s", message);
            end
        end
    endtask

    task pulse_start;
        input [63:0] ptr;
        begin
            @(negedge clk);
            root_descriptor_ptr = ptr;
            start_inference = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            start_inference = 1'b0;
            #1;
            check(active_descriptor_ptr == ptr, "root descriptor pointer captured");
            check(descriptor_fetch_start, "descriptor fetch request pulse asserted");
            @(posedge clk); #1;
            check(!descriptor_fetch_start, "descriptor fetch request is one cycle");
        end
    endtask

    task send_descriptor_result;
        input valid_value;
        input error_value;
        input [7:0] err_code;
        input [63:0] next_ptr;
        input [63:0] exit_ptr;
        input [5:0] flags;
        begin
            @(negedge clk);
            descriptor_done = 1'b1;
            descriptor_valid = valid_value;
            config_error = error_value;
            descriptor_error_code = err_code;
            next_descriptor_ptr = next_ptr;
            exit_descriptor_ptr = exit_ptr;
            cfg_flags = flags;
            @(posedge clk); #1;
            @(negedge clk);
            descriptor_done = 1'b0;
            descriptor_valid = 1'b0;
            config_error = 1'b0;
            descriptor_error_code = 8'h00;
            #1;
        end
    endtask

    task finish_compute;
        begin
            // Must remain busy if no complete-compute handshake has arrived.
            repeat (2) begin
                @(posedge clk); #1;
                check(busy && !output_write_start,
                      "sequencer waits for compute_done before writeback");
            end
            @(negedge clk);
            compute_done = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            compute_done = 1'b0;
            #1;
        end
    endtask

    task finish_writeback;
        begin
            check(output_write_start, "output writeback start pulse asserted");
            @(posedge clk); #1; // enter wait-writeback state
            @(negedge clk);
            writeback_done = 1'b1;
            @(posedge clk); #1;
            @(negedge clk);
            writeback_done = 1'b0;
            #1;
            @(posedge clk); #1; // route decision
        end
    endtask

    initial begin
        clk=0; rst_n=0;
        start_inference=0; root_descriptor_ptr=0;
        descriptor_done=0; descriptor_valid=0; config_error=0;
        descriptor_error_code=0; next_descriptor_ptr=0;
        exit_descriptor_ptr=0; cfg_flags=0;
        compute_done=0; confidence_done=0; early_exit_trigger=0;
        global_early_exit_enable=1; writeback_done=0;
        engine_error=0; engine_error_code=0; checks=0;

        repeat (2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        check(!busy && !inference_complete && !error,
              "reset starts idle with no completion or error");

        // Scenario 1: normal two-layer traversal, then terminal completion.
        pulse_start(64'h0000_0000_0000_1000);
        send_descriptor_result(1'b1, 1'b0, 8'h00,
                               64'h0000_0000_0000_2000, 64'd0, 6'b000000);
        check(layer_start && !confidence_eval_start,
              "valid non-exit layer launches compute without confidence start");
        @(posedge clk); #1; // ST_WAIT_COMP
        finish_compute();
        finish_writeback();
        check(active_descriptor_ptr == 64'h0000_0000_0000_2000 &&
              descriptor_fetch_start,
              "NEXT_DESC selected only after writeback completes");

        @(posedge clk); #1; // enter WAIT_DESC for second layer
        send_descriptor_result(1'b1, 1'b0, 8'h00,
                               64'd0, 64'd0, 6'b000000);
        check(layer_start, "second layer launches after valid descriptor");
        @(posedge clk); #1;
        finish_compute();
        finish_writeback();
        check(inference_complete && !busy && !error,
              "terminal layer completes inference after writeback");

        // ReLU is descriptor CFG bit 4; it must not be mistaken for EXIT_HEAD.
        pulse_start(64'h0000_0000_0000_2800);
        send_descriptor_result(1'b1, 1'b0, 8'h00,
                               64'd0, 64'd0, 6'b010000);
        check(layer_start && !confidence_eval_start,
              "ReLU descriptor flag does not start confidence evaluation");
        @(posedge clk); #1;
        finish_compute();
        finish_writeback();
        check(inference_complete && !early_exit_occurred && !error,
              "ReLU-flag terminal layer completes without taking early exit");

        // Scenario 2: early-exit branch to a nonzero EXIT_DESC.
        pulse_start(64'h0000_0000_0000_3000);
        send_descriptor_result(1'b1, 1'b0, 8'h00,
                               64'h0000_0000_0000_4000,
                               64'h0000_0000_0000_9000,
                               6'b001000); // cfg_flags[3] = EXIT_HEAD per descriptor v1
        check(layer_start && confidence_eval_start,
              "eligible exit-head starts confidence evaluation");
        @(posedge clk); #1; // ST_WAIT_COMP
        // This layer waits for compute_done before confidence result is consumed.
        @(negedge clk); compute_done=1'b1;
        @(posedge clk); #1;
        @(negedge clk); compute_done=1'b0;
        #1;
        check(busy && !output_write_start,
              "exit head waits for confidence completion");
        @(negedge clk);
        confidence_done=1'b1;
        early_exit_trigger=1'b1;
        @(posedge clk); #1;
        @(negedge clk);
        confidence_done=1'b0;
        early_exit_trigger=1'b0;
        #1;
        finish_writeback();
        check(active_descriptor_ptr == 64'h0000_0000_0000_9000 &&
              descriptor_fetch_start && early_exit_occurred,
              "early exit selects EXIT_DESC after writeback");

        @(posedge clk); #1; // enter WAIT_DESC for exit branch
        send_descriptor_result(1'b1, 1'b0, 8'h00, 64'd0, 64'd0, 6'b000000);
        check(layer_start, "exit branch descriptor is fetched and launched");
        @(posedge clk); #1;
        finish_compute();
        finish_writeback();
        check(inference_complete && early_exit_occurred && !error,
              "inference completes on terminal exit branch");

        // Scenario 3: invalid descriptor stops before compute starts.
        pulse_start(64'h0000_0000_0000_5000);
        send_descriptor_result(1'b0, 1'b1, 8'h03,
                               64'h0000_0000_0000_6000, 64'd0, 6'b000000);
        check(error && !busy && !layer_start && error_code == 8'h03,
              "invalid descriptor propagates its error without launching compute");

        // Scenario 4: runtime engine error is propagated and halts the FSM.
        pulse_start(64'h0000_0000_0000_7000);
        send_descriptor_result(1'b1, 1'b0, 8'h00, 64'd0, 64'd0, 6'b000000);
        check(layer_start, "valid descriptor starts before injected engine error");
        @(posedge clk); #1; // ST_WAIT_COMP
        @(negedge clk); engine_error=1'b1; engine_error_code=8'h22;
        @(posedge clk); #1;
        @(negedge clk); engine_error=1'b0; engine_error_code=0;
        #1;
        check(error && !busy && error_code == 8'h22,
              "engine error aborts active work and preserves error code");

        $display("");
        $display("SEQUENCER FSM V2 TEST SUMMARY");
        $display("Checks run: %0d", checks);
        $display("Failures : 0");
        $display("SEQUENCER FSM VERIFICATION PASSED");
        $finish;
    end
endmodule
