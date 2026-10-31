`timescale 1ns/1ps
// 4x4 registered systolic MAC mesh.
// - 16-bit packed operands propagate east (activations) and south (weights).
// - The tile feeder MUST skew activation row r by r cycles and weight column c
//   by c cycles. This makes the kth A and B tokens meet at PE[r][c].
// - INT8 mode accumulates two independent signed byte lanes.
// - INT4 mode accumulates four independent signed nibble lanes.
// - Each SIMD lane has a signed 32-bit accumulator (128 bits per PE total).
// - FP16 is intentionally unsupported in this integer prototype.
// - `advance` stalls all mesh registers and accumulators together. While it is
//   low, the feeder must hold its input payload/valid/last signals stable.
module systolic_array_v2 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         advance,
    input  wire         acc_clear,
    input  wire         acc_enable,
    input  wire [1:0]   precision_mode,  // 01 INT8, 10 INT4
    input  wire         zero_bypass_enable, // Descriptor CFG bit 2; per SIMD lane

    input  wire [15:0]  act_row_in [0:3],
    input  wire [3:0]   act_row_valid,
    input  wire [3:0]   act_row_last,

    input  wire [15:0]  weight_col_in [0:3],
    input  wire [3:0]   weight_col_valid,
    input  wire [3:0]   weight_col_last,

    output wire [127:0] pe_accum_out [0:3][0:3],
    output wire [15:0]  pe_result_valid, // bit (r*4+c) identifies PE[r][c]
    output reg          tile_done,
    output reg          config_error,
    output reg          protocol_error,
    output wire         accum_overflow,
    output reg  [31:0]  zero_skip_count // Counts valid SIMD lane-products bypassed
);
    wire [15:0] act_pipe [0:3][0:4];
    wire [15:0] weight_pipe [0:4][0:3];
    wire        act_valid_pipe [0:3][0:4];
    wire        weight_valid_pipe [0:4][0:3];
    wire        act_last_pipe [0:3][0:4];
    wire        weight_last_pipe [0:4][0:3];

    reg [15:0] act_delay [0:3][0:3];
    reg [15:0] weight_delay [0:3][0:3];
    reg        act_valid_delay [0:3][0:3];
    reg        weight_valid_delay [0:3][0:3];
    reg        act_last_delay [0:3][0:3];
    reg        weight_last_delay [0:3][0:3];

    wire [15:0] finish_mask;
    wire [15:0] mismatch_mask;
    wire [15:0] valid_pair_mask;
    wire [15:0] pe_overflow_mask;
    wire [63:0] zero_skip_mask;
    reg  [6:0]  skip_increment;
    integer skip_i;
    reg  [15:0] result_seen;
    reg  [15:0] result_valid_reg;

    assign pe_result_valid = result_valid_reg;
    assign accum_overflow = |pe_overflow_mask;

    function [31:0] saturate_sum;
        input [32:0] wide_sum;
        begin
            if (!wide_sum[32] && wide_sum[31])
                saturate_sum = 32'h7fff_ffff;
            else if (wide_sum[32] && !wide_sum[31])
                saturate_sum = 32'h8000_0000;
            else
                saturate_sum = wide_sum[31:0];
        end
    endfunction

    genvar r, c;
    generate
        for (r = 0; r < 4; r = r + 1) begin : gen_row_inputs
            assign act_pipe[r][0] = act_row_in[r];
            assign act_valid_pipe[r][0] = act_row_valid[r];
            assign act_last_pipe[r][0] = act_row_last[r];
        end
        for (c = 0; c < 4; c = c + 1) begin : gen_col_inputs
            assign weight_pipe[0][c] = weight_col_in[c];
            assign weight_valid_pipe[0][c] = weight_col_valid[c];
            assign weight_last_pipe[0][c] = weight_col_last[c];
        end

        for (r = 0; r < 4; r = r + 1) begin : gen_rows
            for (c = 0; c < 4; c = c + 1) begin : gen_cols
                wire mac_valid;
                wire mac_last;
                wire signed [7:0]  i8_a0_gated, i8_b0_gated;
                wire signed [7:0]  i8_a1_gated, i8_b1_gated;
                wire               i8_zero0, i8_zero1;
                wire               i8_skip0, i8_skip1;
                wire signed [15:0] i8_prod0;
                wire signed [15:0] i8_prod1;
                wire signed [3:0]  i4_a0_gated, i4_b0_gated;
                wire signed [3:0]  i4_a1_gated, i4_b1_gated;
                wire signed [3:0]  i4_a2_gated, i4_b2_gated;
                wire signed [3:0]  i4_a3_gated, i4_b3_gated;
                wire               i4_zero0, i4_zero1, i4_zero2, i4_zero3;
                wire               i4_skip0, i4_skip1, i4_skip2, i4_skip3;
                wire signed [7:0]  i4_prod0;
                wire signed [7:0]  i4_prod1;
                wire signed [7:0]  i4_prod2;
                wire signed [7:0]  i4_prod3;

                reg signed [31:0] acc0;
                reg signed [31:0] acc1;
                reg signed [31:0] acc2;
                reg signed [31:0] acc3;
                reg pe_overflow;

                wire signed [32:0] sum_i8_0;
                wire signed [32:0] sum_i8_1;
                wire signed [32:0] sum_i4_0;
                wire signed [32:0] sum_i4_1;
                wire signed [32:0] sum_i4_2;
                wire signed [32:0] sum_i4_3;

                assign act_pipe[r][c+1] = act_delay[r][c];
                assign weight_pipe[r+1][c] = weight_delay[r][c];
                assign act_valid_pipe[r][c+1] = act_valid_delay[r][c];
                assign weight_valid_pipe[r+1][c] = weight_valid_delay[r][c];
                assign act_last_pipe[r][c+1] = act_last_delay[r][c];
                assign weight_last_pipe[r+1][c] = weight_last_delay[r][c];

                // Descriptor CFG bit 2 enables per-lane zero bypass. Gate both
                // multiplier inputs when either operand in that lane is zero.
                assign i8_zero0 = (act_pipe[r][c][7:0] == 8'd0) ||
                                  (weight_pipe[r][c][7:0] == 8'd0);
                assign i8_zero1 = (act_pipe[r][c][15:8] == 8'd0) ||
                                  (weight_pipe[r][c][15:8] == 8'd0);
                assign i8_skip0 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b01) && i8_zero0;
                assign i8_skip1 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b01) && i8_zero1;
                assign i8_a0_gated = (zero_bypass_enable && i8_zero0) ? 8'sd0 : $signed(act_pipe[r][c][7:0]);
                assign i8_b0_gated = (zero_bypass_enable && i8_zero0) ? 8'sd0 : $signed(weight_pipe[r][c][7:0]);
                assign i8_a1_gated = (zero_bypass_enable && i8_zero1) ? 8'sd0 : $signed(act_pipe[r][c][15:8]);
                assign i8_b1_gated = (zero_bypass_enable && i8_zero1) ? 8'sd0 : $signed(weight_pipe[r][c][15:8]);
                assign i8_prod0 = i8_a0_gated * i8_b0_gated;
                assign i8_prod1 = i8_a1_gated * i8_b1_gated;

                assign i4_zero0 = (act_pipe[r][c][3:0] == 4'd0) ||
                                  (weight_pipe[r][c][3:0] == 4'd0);
                assign i4_zero1 = (act_pipe[r][c][7:4] == 4'd0) ||
                                  (weight_pipe[r][c][7:4] == 4'd0);
                assign i4_zero2 = (act_pipe[r][c][11:8] == 4'd0) ||
                                  (weight_pipe[r][c][11:8] == 4'd0);
                assign i4_zero3 = (act_pipe[r][c][15:12] == 4'd0) ||
                                  (weight_pipe[r][c][15:12] == 4'd0);
                assign i4_skip0 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b10) && i4_zero0;
                assign i4_skip1 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b10) && i4_zero1;
                assign i4_skip2 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b10) && i4_zero2;
                assign i4_skip3 = zero_bypass_enable && mac_valid &&
                                  (precision_mode == 2'b10) && i4_zero3;
                assign i4_a0_gated = (zero_bypass_enable && i4_zero0) ? 4'sd0 : $signed(act_pipe[r][c][3:0]);
                assign i4_b0_gated = (zero_bypass_enable && i4_zero0) ? 4'sd0 : $signed(weight_pipe[r][c][3:0]);
                assign i4_a1_gated = (zero_bypass_enable && i4_zero1) ? 4'sd0 : $signed(act_pipe[r][c][7:4]);
                assign i4_b1_gated = (zero_bypass_enable && i4_zero1) ? 4'sd0 : $signed(weight_pipe[r][c][7:4]);
                assign i4_a2_gated = (zero_bypass_enable && i4_zero2) ? 4'sd0 : $signed(act_pipe[r][c][11:8]);
                assign i4_b2_gated = (zero_bypass_enable && i4_zero2) ? 4'sd0 : $signed(weight_pipe[r][c][11:8]);
                assign i4_a3_gated = (zero_bypass_enable && i4_zero3) ? 4'sd0 : $signed(act_pipe[r][c][15:12]);
                assign i4_b3_gated = (zero_bypass_enable && i4_zero3) ? 4'sd0 : $signed(weight_pipe[r][c][15:12]);
                assign i4_prod0 = i4_a0_gated * i4_b0_gated;
                assign i4_prod1 = i4_a1_gated * i4_b1_gated;
                assign i4_prod2 = i4_a2_gated * i4_b2_gated;
                assign i4_prod3 = i4_a3_gated * i4_b3_gated;

                assign mac_valid = act_valid_pipe[r][c] && weight_valid_pipe[r][c];
                assign mac_last = mac_valid && act_last_pipe[r][c] && weight_last_pipe[r][c];

                assign sum_i8_0 = $signed({acc0[31], acc0}) +
                                  $signed({{17{i8_prod0[15]}}, i8_prod0});
                assign sum_i8_1 = $signed({acc1[31], acc1}) +
                                  $signed({{17{i8_prod1[15]}}, i8_prod1});
                assign sum_i4_0 = $signed({acc0[31], acc0}) +
                                  $signed({{25{i4_prod0[7]}}, i4_prod0});
                assign sum_i4_1 = $signed({acc1[31], acc1}) +
                                  $signed({{25{i4_prod1[7]}}, i4_prod1});
                assign sum_i4_2 = $signed({acc2[31], acc2}) +
                                  $signed({{25{i4_prod2[7]}}, i4_prod2});
                assign sum_i4_3 = $signed({acc3[31], acc3}) +
                                  $signed({{25{i4_prod3[7]}}, i4_prod3});

                assign pe_accum_out[r][c] = {acc3, acc2, acc1, acc0};
                assign finish_mask[r*4+c] = (advance && acc_enable) ? mac_last : 1'b0;
                assign mismatch_mask[r*4+c] = (act_valid_pipe[r][c] ^ weight_valid_pipe[r][c]);
                assign valid_pair_mask[r*4+c] = mac_valid;
                assign pe_overflow_mask[r*4+c] = pe_overflow;
                assign zero_skip_mask[(r*4+c)*4 +: 4] =
                    (precision_mode == 2'b01) ? {2'b00, i8_skip1, i8_skip0} :
                    (precision_mode == 2'b10) ? {i4_skip3, i4_skip2, i4_skip1, i4_skip0} :
                    4'b0000;

                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        act_delay[r][c]        <= 16'd0;
                        weight_delay[r][c]     <= 16'd0;
                        act_valid_delay[r][c]  <= 1'b0;
                        weight_valid_delay[r][c] <= 1'b0;
                        act_last_delay[r][c]   <= 1'b0;
                        weight_last_delay[r][c] <= 1'b0;
                        acc0                   <= 32'sd0;
                        acc1                   <= 32'sd0;
                        acc2                   <= 32'sd0;
                        acc3                   <= 32'sd0;
                        pe_overflow            <= 1'b0;
                        result_valid_reg[r*4+c] <= 1'b0;
                    end else if (acc_clear) begin
                        act_delay[r][c]        <= 16'd0;
                        weight_delay[r][c]     <= 16'd0;
                        act_valid_delay[r][c]  <= 1'b0;
                        weight_valid_delay[r][c] <= 1'b0;
                        act_last_delay[r][c]   <= 1'b0;
                        weight_last_delay[r][c] <= 1'b0;
                        acc0                   <= 32'sd0;
                        acc1                   <= 32'sd0;
                        acc2                   <= 32'sd0;
                        acc3                   <= 32'sd0;
                        pe_overflow            <= 1'b0;
                        result_valid_reg[r*4+c] <= 1'b0;
                    end else if (advance) begin
                        // Registered nearest-neighbor forwarding.
                        act_delay[r][c]         <= act_pipe[r][c];
                        weight_delay[r][c]      <= weight_pipe[r][c];
                        act_valid_delay[r][c]   <= act_valid_pipe[r][c];
                        weight_valid_delay[r][c] <= weight_valid_pipe[r][c];
                        act_last_delay[r][c]    <= act_last_pipe[r][c];
                        weight_last_delay[r][c]  <= weight_last_pipe[r][c];
                        result_valid_reg[r*4+c] <= mac_last && acc_enable &&
                                                   ((precision_mode == 2'b01) ||
                                                    (precision_mode == 2'b10));

                        if (mac_valid && acc_enable) begin
                            if (precision_mode == 2'b01) begin
                                if (!i8_skip0) acc0 <= saturate_sum(sum_i8_0);
                                if (!i8_skip1) acc1 <= saturate_sum(sum_i8_1);
                                if ((sum_i8_0[32] ^ sum_i8_0[31]) ||
                                    (sum_i8_1[32] ^ sum_i8_1[31]))
                                    pe_overflow <= 1'b1;
                            end else if (precision_mode == 2'b10) begin
                                if (!i4_skip0) acc0 <= saturate_sum(sum_i4_0);
                                if (!i4_skip1) acc1 <= saturate_sum(sum_i4_1);
                                if (!i4_skip2) acc2 <= saturate_sum(sum_i4_2);
                                if (!i4_skip3) acc3 <= saturate_sum(sum_i4_3);
                                if ((sum_i4_0[32] ^ sum_i4_0[31]) ||
                                    (sum_i4_1[32] ^ sum_i4_1[31]) ||
                                    (sum_i4_2[32] ^ sum_i4_2[31]) ||
                                    (sum_i4_3[32] ^ sum_i4_3[31]))
                                    pe_overflow <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // Up to 16 PEs x 4 SIMD lanes may be bypassed in one accepted mesh cycle.
    always @* begin
        skip_increment = 7'd0;
        for (skip_i = 0; skip_i < 64; skip_i = skip_i + 1)
            if (zero_skip_mask[skip_i]) skip_increment = skip_increment + 7'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) zero_skip_count <= 32'd0;
        else if (acc_clear) zero_skip_count <= 32'd0;
        else if (advance && acc_enable && (skip_increment != 7'd0))
            zero_skip_count <= zero_skip_count + skip_increment;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_seen    <= 16'd0;
            tile_done      <= 1'b0;
            config_error   <= 1'b0;
            protocol_error <= 1'b0;
        end else if (acc_clear) begin
            result_seen    <= 16'd0;
            tile_done      <= 1'b0;
            config_error   <= 1'b0;
            protocol_error <= 1'b0;
        end else if (advance) begin
            result_seen <= result_seen | finish_mask;

            // Sticky completion: retain tile_done until reset or acc_clear.
            if (!tile_done &&
                !( &result_seen) &&
                ( &(result_seen | finish_mask) ))
                tile_done <= 1'b1;

            if (|(mismatch_mask & 16'hffff))
                protocol_error <= 1'b1;

            if (acc_enable && (|valid_pair_mask) &&
                !((precision_mode == 2'b01) || (precision_mode == 2'b10)))
                config_error <= 1'b1;
        end
    end
endmodule
