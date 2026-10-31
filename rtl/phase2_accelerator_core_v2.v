`timescale 1ns/1ps
// Phase 2 single-tile integration core.
// Integrates: 32-word descriptor parser, sequencer FSM v2, two AGUs,
// activation/weight ping-pong scratchpads, tile-word response buffering,
// skew feeder, registered 4x4 systolic mesh, and SIMD-lane reduction/requantization.
// External interfaces model the future DMA engines and output writer.
// Version 1 integration is deliberately one 4x4 output tile (M=N=4).
module phase2_accelerator_core_v2 #(
    parameter integer SCRATCH_ADDR_WIDTH = 8
) (
    input wire clk,
    input wire rst_n,

    // Controller / descriptor-fetch stream (the fetch DMA is Phase 3).
    input wire start_inference,
    input wire [63:0] root_descriptor_ptr,
    input wire global_early_exit_enable,
    output wire descriptor_fetch_start,
    output wire [63:0] active_descriptor_ptr,
    input wire descriptor_word_valid,
    output wire descriptor_word_ready,
    input wire [4:0] descriptor_word_index,
    input wire [31:0] descriptor_word_data,

    // Activation and weight DMA read-address request interfaces.
    output wire act_addr_valid,
    input wire act_addr_ready,
    output wire [31:0] act_addr,
    output wire act_agu_busy,
    output wire act_agu_done,
    output wire weight_addr_valid,
    input wire weight_addr_ready,
    output wire [31:0] weight_addr,
    output wire weight_agu_busy,
    output wire weight_agu_done,

    // Activation scratchpad DMA response/write interface.
    input wire act_dma_write_valid,
    output wire act_dma_write_ready,
    input wire [SCRATCH_ADDR_WIDTH-1:0] act_dma_write_addr,
    input wire [63:0] act_dma_write_data,
    input wire act_dma_commit,
    output wire act_dma_commit_ready,
    output wire act_prefetch_complete,
    input wire act_bank_swap_req,
    output wire act_bank_swap_ack,
    output wire act_bank_swap_rejected,
    output wire act_active_bank,

    // Weight scratchpad DMA response/write interface.
    input wire weight_dma_write_valid,
    output wire weight_dma_write_ready,
    input wire [SCRATCH_ADDR_WIDTH-1:0] weight_dma_write_addr,
    input wire [63:0] weight_dma_write_data,
    input wire weight_dma_commit,
    output wire weight_dma_commit_ready,
    output wire weight_prefetch_complete,
    input wire weight_bank_swap_req,
    output wire weight_bank_swap_ack,
    output wire weight_bank_swap_rejected,
    output wire weight_active_bank,
    output wire banks_ready,

    // Internal single-tile reader trace; SRAM reads are scheduled by this core.
    output wire tile_word_read_req,
    output wire tile_word_read_ready,
    output wire [SCRATCH_ADDR_WIDTH-1:0] tile_word_read_addr,
    output wire tile_word_read_last,

    // Global mesh advance (tie high when no downstream stall is required).
    input wire array_advance,

    // Confidence result handshake from the classifier/output-head evaluator.
    input wire confidence_done,
    input wire early_exit_trigger,
    output wire confidence_eval_start,
    output wire layer_start,

    // Output writer handshake (actual AXI write DMA is Phase 3).
    input wire [15:0] postproc_result_ready,
    output wire [15:0] postproc_result_valid,
    output wire [15:0] postproc_result_data [0:3][0:3],
    output wire postproc_tile_done,
    output wire [31:0] saturation_count,
    input wire writeback_done,
    output wire output_write_start,

    // Descriptor fields exposed to the tile scheduler/driver.
    output wire [63:0] a_base,
    output wire [63:0] b_base,
    output wire [63:0] c_base,
    output wire [15:0] m_dim,
    output wire [15:0] n_dim,
    output wire [15:0] k_dim,
    output wire [15:0] k_groups,
    output wire [31:0] a_tile_stride_bytes,
    output wire [31:0] b_tile_stride_bytes,
    output wire [31:0] c_tile_stride_bytes,
    output wire [1:0] precision_mode,
    output wire [31:0] scale_m0,
    output wire [4:0] shift_n,
    output wire [7:0] zero_point_z,
    output wire [31:0] confidence_threshold,
    output wire [31:0] deadline_cycles,
    output wire [31:0] layer_id,
    output wire [5:0] cfg_flags,

    // Array/debug/telemetry outputs.
    output wire [127:0] pe_accum_out [0:3][0:3],
    output wire [15:0] pe_result_valid,
    output wire array_tile_done,
    output wire array_config_error,
    output wire array_protocol_error,
    output wire accum_overflow,
    output wire [31:0] zero_skip_count,

    // External errors and overall inference status.
    input wire external_engine_error,
    input wire [7:0] external_engine_error_code,
    output wire busy,
    output wire inference_complete,
    output wire early_exit_occurred,
    output wire error,
    output wire [7:0] error_code
);
    wire [63:0] next_descriptor_ptr, exit_descriptor_ptr, bias_base;
    wire [31:0] conf_thresh;
    wire descriptor_done, descriptor_valid, descriptor_config_error;
    wire [7:0] descriptor_error_code;
    wire [63:0] descriptor_a_base;
    wire [63:0] descriptor_weight_base;
    wire [63:0] descriptor_output_base;
    wire [31:0] descriptor_a_stride, descriptor_b_stride, descriptor_c_stride;
    wire [15:0] descriptor_m, descriptor_n, descriptor_k;
    wire [5:0] descriptor_flags;
    wire [31:0] descriptor_scale, descriptor_deadline, descriptor_layer_id;
    wire [4:0] descriptor_shift;
    wire [7:0] descriptor_zero_point;

    reg descriptor_fetch_active;
    wire descriptor_load_en = descriptor_word_valid && descriptor_word_ready;
    assign descriptor_word_ready = descriptor_fetch_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) descriptor_fetch_active <= 1'b0;
        else begin
            if (descriptor_fetch_start) descriptor_fetch_active <= 1'b1;
            if (descriptor_done || (descriptor_load_en && (descriptor_word_index == 5'd31)))
                descriptor_fetch_active <= 1'b0;
        end
    end

    descriptor_engine #(.ADDR_WIDTH(32)) descriptor_inst (
        .clk(clk), .rst_n(rst_n),
        .load_descriptor_en(descriptor_load_en),
        .descriptor_word_in(descriptor_word_data),
        .word_index(descriptor_word_index),
        .start_ptr(descriptor_a_base), .front_ptr(next_descriptor_ptr),
        .exit_ptr(exit_descriptor_ptr), .precision_mode(precision_mode),
        .scale_m0(scale_m0), .shift_n(shift_n), .zero_point_z(zero_point_z),
        .conf_thresh(conf_thresh), .weight_base(descriptor_weight_base),
        .output_base(descriptor_output_base), .bias_base(bias_base),
        .m_dim(descriptor_m), .n_dim(descriptor_n), .k_dim(descriptor_k),
        .a_tile_stride_bytes(descriptor_a_stride),
        .b_tile_stride_bytes(descriptor_b_stride),
        .c_tile_stride_bytes(descriptor_c_stride),
        .deadline_cycles(descriptor_deadline), .layer_id(descriptor_layer_id),
        .cfg_flags(descriptor_flags), .descriptor_done(descriptor_done),
        .descriptor_valid(descriptor_valid), .config_error(descriptor_config_error),
        .error_code(descriptor_error_code)
    );

    // This integration top deliberately validates one complete 4x4 output tile.
    // Multi-tile traversal is a separate scheduler extension; M/N are not silently truncated.
    wire integration_shape_ok = (descriptor_m == 16'd4) &&
                                (descriptor_n == 16'd4) &&
                                (k_groups != 16'd0) &&
                                (k_groups <= (1 << SCRATCH_ADDR_WIDTH));
    wire descriptor_valid_to_fsm = descriptor_valid && integration_shape_ok;
    wire descriptor_error_to_fsm = descriptor_config_error ||
                                   (descriptor_valid && !integration_shape_ok);
    wire [7:0] descriptor_error_code_to_fsm = descriptor_config_error ?
                                               descriptor_error_code : 8'h20;

    assign a_base = descriptor_a_base;
    assign b_base = descriptor_weight_base;
    assign c_base = descriptor_output_base;
    assign confidence_threshold = conf_thresh;
    assign m_dim = descriptor_m;
    assign n_dim = descriptor_n;
    assign k_dim = descriptor_k;
    assign a_tile_stride_bytes = descriptor_a_stride;
    assign b_tile_stride_bytes = descriptor_b_stride;
    assign c_tile_stride_bytes = descriptor_c_stride;
    assign deadline_cycles = descriptor_deadline;
    assign layer_id = descriptor_layer_id;
    assign cfg_flags = descriptor_flags;

    wire [16:0] k_groups_wide = (precision_mode == 2'b01) ?
                                (({1'b0, descriptor_k} + 17'd1) >> 1) :
                                (({1'b0, descriptor_k} + 17'd3) >> 2);
    assign k_groups = k_groups_wide[15:0];

    wire layer_start_int;
    wire seq_engine_error;
    reg [7:0] seq_engine_error_code;
    wire act_agu_start_ready, weight_agu_start_ready;
    wire act_agu_error, weight_agu_error;
    wire [2:0] act_agu_error_code, weight_agu_error_code;
    wire act_sram_read_valid, weight_sram_read_valid;
    wire [63:0] act_sram_read_data, weight_sram_read_data;
    reg sram_read_outstanding;
    reg tile_word_valid;
    reg tile_word_last_q;
    reg [63:0] act_word_q, weight_word_q;
    reg memory_pair_error;
    reg banks_ready_reg;
    reg act_swap_ack_seen, weight_swap_ack_seen;
    reg swap_req_d;
    reg act_agu_done_seen, weight_agu_done_seen;
    reg tile_read_active, array_compute_active;
    reg [SCRATCH_ADDR_WIDTH-1:0] tile_read_index;
    wire core_clear = layer_start;

    assign banks_ready = banks_ready_reg;
    assign tile_word_read_req = tile_read_active;
    assign tile_word_read_addr = tile_read_index;
    assign tile_word_read_last = (k_groups != 16'd0) &&
                                 (tile_read_index == (k_groups - 16'd1));
    assign tile_word_read_ready = banks_ready_reg && array_advance &&
                                  !sram_read_outstanding && !tile_word_valid &&
                                  !act_bank_swap_req && !weight_bank_swap_req;
    wire tile_word_read_fire = tile_word_read_req && tile_word_read_ready;
    wire array_acc_enable_int = array_compute_active;

    // Bank acknowledgements are latched independently. This avoids requiring
    // the two SRAM instances to return their one-cycle ACK pulses in the same cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            banks_ready_reg    <= 1'b0;
            act_swap_ack_seen  <= 1'b0;
            weight_swap_ack_seen <= 1'b0;
            swap_req_d         <= 1'b0;
        end else if (core_clear) begin
            // Every new layer must prefetch and commit its own A/B tiles;
            // never reuse the previous layer's banks merely because they remain active.
            banks_ready_reg      <= 1'b0;
            act_swap_ack_seen    <= 1'b0;
            weight_swap_ack_seen <= 1'b0;
            swap_req_d           <= 1'b0;
        end else begin
            swap_req_d <= act_bank_swap_req || weight_bank_swap_req;
            if ((act_bank_swap_req || weight_bank_swap_req) && !swap_req_d) begin
                banks_ready_reg      <= 1'b0;
                act_swap_ack_seen    <= 1'b0;
                weight_swap_ack_seen <= 1'b0;
            end
            if (act_bank_swap_ack) act_swap_ack_seen <= 1'b1;
            if (weight_bank_swap_ack) weight_swap_ack_seen <= 1'b1;
            if ((act_swap_ack_seen || act_bank_swap_ack) &&
                (weight_swap_ack_seen || weight_bank_swap_ack))
                banks_ready_reg <= 1'b1;
        end
    end

    // One-tile scheduler: start only after both AGUs have issued every address
    // AND both scratchpads have acknowledged the ownership swap.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sram_read_outstanding <= 1'b0;
            tile_word_valid       <= 1'b0;
            tile_word_last_q      <= 1'b0;
            act_word_q            <= 64'd0;
            weight_word_q         <= 64'd0;
            memory_pair_error     <= 1'b0;
            act_agu_done_seen     <= 1'b0;
            weight_agu_done_seen  <= 1'b0;
            tile_read_active      <= 1'b0;
            array_compute_active  <= 1'b0;
            tile_read_index       <= {SCRATCH_ADDR_WIDTH{1'b0}};
        end else if (core_clear) begin
            sram_read_outstanding <= 1'b0;
            tile_word_valid       <= 1'b0;
            tile_word_last_q      <= 1'b0;
            memory_pair_error     <= 1'b0;
            act_agu_done_seen     <= 1'b0;
            weight_agu_done_seen  <= 1'b0;
            tile_read_active      <= 1'b0;
            array_compute_active  <= 1'b0;
            tile_read_index       <= {SCRATCH_ADDR_WIDTH{1'b0}};
        end else begin
            if (act_agu_done) act_agu_done_seen <= 1'b1;
            if (weight_agu_done) weight_agu_done_seen <= 1'b1;

            if (!array_compute_active && banks_ready_reg &&
                (act_agu_done_seen || act_agu_done) &&
                (weight_agu_done_seen || weight_agu_done)) begin
                array_compute_active <= 1'b1;
                tile_read_active <= 1'b1;
                tile_read_index <= {SCRATCH_ADDR_WIDTH{1'b0}};
            end

            if (tile_word_read_fire) begin
                sram_read_outstanding <= 1'b1;
                tile_word_last_q <= tile_word_read_last;
                if (tile_word_read_last)
                    tile_read_active <= 1'b0;
                else
                    tile_read_index <= tile_read_index + 1'b1;
            end

            if (act_sram_read_valid || weight_sram_read_valid) begin
                sram_read_outstanding <= 1'b0;
                if (act_sram_read_valid && weight_sram_read_valid) begin
                    act_word_q <= act_sram_read_data;
                    weight_word_q <= weight_sram_read_data;
                    tile_word_valid <= 1'b1;
                end else begin
                    memory_pair_error <= 1'b1;
                end
            end

            if (tile_word_valid && array_advance)
                tile_word_valid <= 1'b0;

            if (array_tile_done)
                array_compute_active <= 1'b0;

            // Stop issuing additional scratchpad reads immediately after any
            // latched engine/mesh/protocol error reaches the sequencer.
            if (seq_engine_error) begin
                tile_read_active <= 1'b0;
                array_compute_active <= 1'b0;
                sram_read_outstanding <= 1'b0;
                tile_word_valid <= 1'b0;
            end
        end
    end

    agu_v2 #(.ADDR_WIDTH(32), .WORD_BYTES(8)) act_agu_inst (
        .clk(clk), .rst_n(rst_n), .start_valid(layer_start),
        .start_ready(act_agu_start_ready), .base_addr(descriptor_a_base[31:0]),
        .rows(16'd1), .words_per_row(k_groups),
        .row_stride_bytes(descriptor_a_stride), .addr_valid(act_addr_valid),
        .addr_ready(act_addr_ready), .addr(act_addr), .busy(act_agu_busy),
        .done(act_agu_done), .error(act_agu_error), .error_code(act_agu_error_code)
    );

    agu_v2 #(.ADDR_WIDTH(32), .WORD_BYTES(8)) weight_agu_inst (
        .clk(clk), .rst_n(rst_n), .start_valid(layer_start),
        .start_ready(weight_agu_start_ready), .base_addr(descriptor_weight_base[31:0]),
        .rows(16'd1), .words_per_row(k_groups),
        .row_stride_bytes(descriptor_b_stride), .addr_valid(weight_addr_valid),
        .addr_ready(weight_addr_ready), .addr(weight_addr), .busy(weight_agu_busy),
        .done(weight_agu_done), .error(weight_agu_error), .error_code(weight_agu_error_code)
    );

    ping_pong_sram_v2 #(.DATA_WIDTH(64), .ADDR_WIDTH(SCRATCH_ADDR_WIDTH)) act_sram_inst (
        .clk(clk), .rst_n(rst_n),
        .dma_write_valid(act_dma_write_valid), .dma_write_ready(act_dma_write_ready),
        .dma_write_addr(act_dma_write_addr), .dma_write_data(act_dma_write_data),
        .dma_commit(act_dma_commit), .dma_commit_ready(act_dma_commit_ready),
        .prefetch_complete(act_prefetch_complete), .bank_swap_req(act_bank_swap_req),
        .bank_swap_ack(act_bank_swap_ack), .bank_swap_rejected(act_bank_swap_rejected),
        .active_bank(act_active_bank), .compute_read_en(tile_word_read_fire),
        .compute_read_addr(tile_word_read_addr), .compute_read_valid(act_sram_read_valid),
        .compute_read_data(act_sram_read_data)
    );

    ping_pong_sram_v2 #(.DATA_WIDTH(64), .ADDR_WIDTH(SCRATCH_ADDR_WIDTH)) weight_sram_inst (
        .clk(clk), .rst_n(rst_n),
        .dma_write_valid(weight_dma_write_valid), .dma_write_ready(weight_dma_write_ready),
        .dma_write_addr(weight_dma_write_addr), .dma_write_data(weight_dma_write_data),
        .dma_commit(weight_dma_commit), .dma_commit_ready(weight_dma_commit_ready),
        .prefetch_complete(weight_prefetch_complete), .bank_swap_req(weight_bank_swap_req),
        .bank_swap_ack(weight_bank_swap_ack), .bank_swap_rejected(weight_bank_swap_rejected),
        .active_bank(weight_active_bank), .compute_read_en(tile_word_read_fire),
        .compute_read_addr(tile_word_read_addr), .compute_read_valid(weight_sram_read_valid),
        .compute_read_data(weight_sram_read_data)
    );

    wire [15:0] act_row_in [0:3];
    wire [3:0] act_row_valid, act_row_last;
    wire [15:0] weight_col_in [0:3];
    wire [3:0] weight_col_valid, weight_col_last;
    wire feeder_input_ready;

    systolic_tile_feeder_v2 feeder_inst (
        .clk(clk), .rst_n(rst_n), .clear(core_clear), .advance(array_advance),
        .act_word(act_word_q), .act_word_valid(tile_word_valid), .act_word_last(tile_word_last_q),
        .weight_word(weight_word_q), .weight_word_valid(tile_word_valid),
        .weight_word_last(tile_word_last_q), .input_ready(feeder_input_ready),
        .act_row_out(act_row_in), .act_row_valid(act_row_valid), .act_row_last(act_row_last),
        .weight_col_out(weight_col_in), .weight_col_valid(weight_col_valid),
        .weight_col_last(weight_col_last)
    );

    systolic_array_v2 array_inst (
        .clk(clk), .rst_n(rst_n), .advance(array_advance),
        .acc_clear(core_clear), .acc_enable(array_acc_enable_int),
        .precision_mode(precision_mode), .zero_bypass_enable(cfg_flags[2]),
        .act_row_in(act_row_in),
        .act_row_valid(act_row_valid), .act_row_last(act_row_last),
        .weight_col_in(weight_col_in), .weight_col_valid(weight_col_valid),
        .weight_col_last(weight_col_last), .pe_accum_out(pe_accum_out),
        .pe_result_valid(pe_result_valid), .tile_done(array_tile_done),
        .config_error(array_config_error), .protocol_error(array_protocol_error),
        .accum_overflow(accum_overflow), .zero_skip_count(zero_skip_count)
    );

    post_processor_mesh_v2 postproc_inst (
        .clk(clk), .rst_n(rst_n), .clear(core_clear),
        .precision_mode(precision_mode), .scale_m0(scale_m0), .shift_n(shift_n),
        .zero_point_z(zero_point_z), .pe_accum_in(pe_accum_out),
        .pe_result_valid(pe_result_valid), .result_ready(postproc_result_ready),
        .result_valid(postproc_result_valid), .result_data(postproc_result_data),
        .tile_done(postproc_tile_done), .saturation_count(saturation_count)
    );

    assign seq_engine_error = external_engine_error || act_agu_error || weight_agu_error ||
                              act_bank_swap_rejected || weight_bank_swap_rejected ||
                              array_config_error || array_protocol_error || accum_overflow ||
                              memory_pair_error || (layer_start &&
                              (!act_agu_start_ready || !weight_agu_start_ready));
    always @* begin
        if (external_engine_error) seq_engine_error_code = external_engine_error_code;
        else if (act_agu_error) seq_engine_error_code = {5'd0, act_agu_error_code};
        else if (weight_agu_error) seq_engine_error_code = {5'd0, weight_agu_error_code};
        else if (act_bank_swap_rejected || weight_bank_swap_rejected) seq_engine_error_code = 8'h34;
        else if (array_config_error) seq_engine_error_code = 8'h31;
        else if (array_protocol_error) seq_engine_error_code = 8'h32;
        else if (accum_overflow) seq_engine_error_code = 8'h33;
        else if (memory_pair_error) seq_engine_error_code = 8'h35;
        else if (layer_start && (!act_agu_start_ready || !weight_agu_start_ready)) seq_engine_error_code = 8'h36;
        else seq_engine_error_code = 8'h00;
    end

    assign layer_start = layer_start_int;

    sequencer_fsm_v2 sequencer_inst (
        .clk(clk), .rst_n(rst_n), .start_inference(start_inference),
        .root_descriptor_ptr(root_descriptor_ptr),
        .descriptor_fetch_start(descriptor_fetch_start),
        .active_descriptor_ptr(active_descriptor_ptr),
        .descriptor_done(descriptor_done), .descriptor_valid(descriptor_valid_to_fsm),
        .config_error(descriptor_error_to_fsm),
        .descriptor_error_code(descriptor_error_code_to_fsm),
        .next_descriptor_ptr(next_descriptor_ptr), .exit_descriptor_ptr(exit_descriptor_ptr),
        .cfg_flags(descriptor_flags), .layer_start(layer_start_int),
        .compute_done(postproc_tile_done),
        .confidence_eval_start(confidence_eval_start),
        .confidence_done(confidence_done), .early_exit_trigger(early_exit_trigger),
        .global_early_exit_enable(global_early_exit_enable),
        .output_write_start(output_write_start), .writeback_done(writeback_done),
        .engine_error(seq_engine_error), .engine_error_code(seq_engine_error_code),
        .busy(busy), .inference_complete(inference_complete),
        .early_exit_occurred(early_exit_occurred), .error(error), .error_code(error_code)
    );
endmodule
