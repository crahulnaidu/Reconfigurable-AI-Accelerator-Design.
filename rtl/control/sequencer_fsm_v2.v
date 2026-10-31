`timescale 1ns/1ps

// Phase 2 Day 7: sequencer with explicit descriptor, compute, writeback,
// confidence, and engine-error handshakes.
//
// This is intentionally named sequencer_fsm_v2 so the legacy top-level module
// is not broken before control_unit_top is migrated in the integration step.
//
// cfg_flags[3] is EXIT_HEAD in descriptor version 1; cfg_flags[4] is ReLU.
// descriptor_done is a one-cycle completion pulse from descriptor_engine;
// descriptor_valid/config_error/error_code must describe that completed frame.
// compute_done means *all tiles and post-processing for the layer are complete*.
// It must not be driven merely from AGU/address-generation completion.
// writeback_done means all required output writes have received successful
// responses. confidence_done must remain asserted with the result until sampled.
module sequencer_fsm_v2 (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_inference,
    input  wire [63:0] root_descriptor_ptr,

    // Descriptor parser / descriptor-fetch side
    output wire        descriptor_fetch_start,
    output reg  [63:0] active_descriptor_ptr,
    input  wire        descriptor_done,
    input  wire        descriptor_valid,
    input  wire        config_error,
    input  wire [7:0]  descriptor_error_code,
    input  wire [63:0] next_descriptor_ptr,
    input  wire [63:0] exit_descriptor_ptr,
    input  wire [5:0]  cfg_flags,

    // Layer execution side
    output wire        layer_start,
    input  wire        compute_done,
    output wire        confidence_eval_start,
    input  wire        confidence_done,
    input  wire        early_exit_trigger,
    input  wire        global_early_exit_enable,
    output wire        output_write_start,
    input  wire        writeback_done,

    // Common error/status interface
    input  wire        engine_error,
    input  wire [7:0]  engine_error_code,
    output wire        busy,
    output wire        inference_complete,
    output reg         early_exit_occurred,
    output wire        error,
    output reg  [7:0]  error_code
);

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_FETCH_REQ   = 4'd1;
    localparam [3:0] ST_WAIT_DESC   = 4'd2;
    localparam [3:0] ST_START_LAYER = 4'd3;
    localparam [3:0] ST_WAIT_COMP   = 4'd4;
    localparam [3:0] ST_WAIT_CONF   = 4'd5;
    localparam [3:0] ST_START_WR    = 4'd6;
    localparam [3:0] ST_WAIT_WR     = 4'd7;
    localparam [3:0] ST_ROUTE       = 4'd8;
    localparam [3:0] ST_DONE        = 4'd9;
    localparam [3:0] ST_ERROR       = 4'd10;

    localparam [7:0] ERR_ENGINE            = 8'hE0;
    localparam [7:0] ERR_INVALID_DESCRIPTOR = 8'hE1;
    localparam integer EXIT_HEAD_BIT = 3; // Descriptor CFG bit 3; bit 4 is ReLU.

    reg [3:0] state;
    reg [63:0] current_next_ptr;
    reg [63:0] current_exit_ptr;
    reg [5:0]  current_cfg_flags;
    reg        early_exit_pending;

    assign descriptor_fetch_start = (state == ST_FETCH_REQ);
    assign layer_start            = (state == ST_START_LAYER);
    assign confidence_eval_start  = (state == ST_START_LAYER) &&
                                    current_cfg_flags[EXIT_HEAD_BIT] &&
                                    global_early_exit_enable;
    assign output_write_start     = (state == ST_START_WR);

    assign busy = (state != ST_IDLE) && (state != ST_DONE) &&
                  (state != ST_ERROR);
    assign inference_complete = (state == ST_DONE);
    assign error = (state == ST_ERROR);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                 <= ST_IDLE;
            active_descriptor_ptr <= 64'd0;
            current_next_ptr      <= 64'd0;
            current_exit_ptr      <= 64'd0;
            current_cfg_flags     <= 6'd0;
            early_exit_pending    <= 1'b0;
            early_exit_occurred   <= 1'b0;
            error_code            <= 8'h00;
        end else begin
            // A new request can be accepted from idle or either terminal state.
            if (start_inference && ((state == ST_IDLE) || (state == ST_DONE) ||
                                    (state == ST_ERROR))) begin
                active_descriptor_ptr <= root_descriptor_ptr;
                current_next_ptr      <= 64'd0;
                current_exit_ptr      <= 64'd0;
                current_cfg_flags     <= 6'd0;
                early_exit_pending    <= 1'b0;
                early_exit_occurred   <= 1'b0;
                error_code            <= 8'h00;
                state                 <= ST_FETCH_REQ;
            end else if (engine_error && busy) begin
                state      <= ST_ERROR;
                error_code <= (engine_error_code != 8'h00) ?
                              engine_error_code : ERR_ENGINE;
            end else begin
                case (state)
                    ST_IDLE: begin
                        // Wait for start_inference.
                    end

                    ST_FETCH_REQ: begin
                        // descriptor_fetch_start is asserted for this state only.
                        state <= ST_WAIT_DESC;
                    end

                    ST_WAIT_DESC: begin
                        if (descriptor_done) begin
                            if (config_error || !descriptor_valid) begin
                                state <= ST_ERROR;
                                if (descriptor_error_code != 8'h00)
                                    error_code <= descriptor_error_code;
                                else
                                    error_code <= ERR_INVALID_DESCRIPTOR;
                            end else begin
                                // Snapshot the accepted descriptor fields. The
                                // parser may overwrite its outputs for the next layer.
                                current_next_ptr   <= next_descriptor_ptr;
                                current_exit_ptr   <= exit_descriptor_ptr;
                                current_cfg_flags  <= cfg_flags;
                                early_exit_pending <= 1'b0;
                                state              <= ST_START_LAYER;
                            end
                        end
                    end

                    ST_START_LAYER: begin
                        // One-cycle launch pulse for the tile/compute pipeline.
                        state <= ST_WAIT_COMP;
                    end

                    ST_WAIT_COMP: begin
                        // compute_done must represent completion of all tiles and
                        // post-processing, not merely completion of address generation.
                        if (compute_done) begin
                            if (global_early_exit_enable &&
                                current_cfg_flags[EXIT_HEAD_BIT])
                                state <= ST_WAIT_CONF;
                            else
                                state <= ST_START_WR;
                        end
                    end

                    ST_WAIT_CONF: begin
                        if (confidence_done) begin
                            early_exit_pending <= global_early_exit_enable &&
                                                  early_exit_trigger;
                            state <= ST_START_WR;
                        end
                    end

                    ST_START_WR: begin
                        // One-cycle request to output DMA/writeback engine.
                        state <= ST_WAIT_WR;
                    end

                    ST_WAIT_WR: begin
                        if (writeback_done)
                            state <= ST_ROUTE;
                    end

                    ST_ROUTE: begin
                        // Route only after the current layer's output writes finish.
                        if (early_exit_pending) begin
                            early_exit_occurred <= 1'b1;
                            early_exit_pending  <= 1'b0;
                            if (current_exit_ptr != 64'd0) begin
                                active_descriptor_ptr <= current_exit_ptr;
                                state <= ST_FETCH_REQ;
                            end else begin
                                // Exit head has no further branch: inference ends.
                                state <= ST_DONE;
                            end
                        end else if (current_next_ptr != 64'd0) begin
                            active_descriptor_ptr <= current_next_ptr;
                            state <= ST_FETCH_REQ;
                        end else begin
                            state <= ST_DONE;
                        end
                    end

                    ST_DONE: begin
                        // Sticky completion until a new request or reset.
                    end

                    ST_ERROR: begin
                        // Sticky error until a new request or reset.
                    end

                    default: begin
                        state      <= ST_ERROR;
                        error_code <= ERR_ENGINE;
                    end
                endcase
            end
        end
    end

endmodule
