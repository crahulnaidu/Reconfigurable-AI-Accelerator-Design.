`timescale 1ns/1ps

// Version-1, 32-word (128-byte) layer descriptor parser.
// Input contract: load_descriptor_en qualifies one 32-bit descriptor word per
// clock; word_index must arrive in order 0..31. Word 0 starts/restarts a frame.
// descriptor_done pulses when a complete frame is accepted or a protocol/format
// error aborts it. descriptor_valid is set only after full-frame validation.
//
// ADDR_WIDTH=32 rejects nonzero upper address words. Use ADDR_WIDTH=64 only
// when the connected memory master/interconnect really implements 64-bit PA.
module descriptor_engine #(
    parameter integer ADDR_WIDTH = 32
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        load_descriptor_en,
    input  wire [31:0] descriptor_word_in,
    input  wire [4:0]  word_index,

    // Legacy names retained for integration: start_ptr is A_BASE,
    // front_ptr is NEXT_DESC, and exit_ptr is EXIT_DESC.
    output reg  [63:0] start_ptr,
    output reg  [63:0] front_ptr,
    output reg  [63:0] exit_ptr,

    output reg  [1:0]  precision_mode,
    output reg  [31:0] scale_m0,
    output reg  [4:0]  shift_n,
    output reg  [7:0]  zero_point_z,
    output reg  [31:0] conf_thresh,

    output reg  [63:0] weight_base,
    output reg  [63:0] output_base,
    output reg  [63:0] bias_base,
    output reg  [15:0] m_dim,
    output reg  [15:0] n_dim,
    output reg  [15:0] k_dim,
    output reg  [31:0] a_tile_stride_bytes,
    output reg  [31:0] b_tile_stride_bytes,
    output reg  [31:0] c_tile_stride_bytes,
    output reg  [31:0] deadline_cycles,
    output reg  [31:0] layer_id,
    output reg  [5:0]  cfg_flags,

    output reg         descriptor_done,
    output reg         descriptor_valid,
    output reg         config_error,
    output reg  [7:0]  error_code
);

    localparam [7:0] ERR_NONE       = 8'h00;
    localparam [7:0] ERR_WORD_ORDER = 8'h01;
    localparam [7:0] ERR_VERSION    = 8'h02;
    localparam [7:0] ERR_PRECISION  = 8'h03;
    localparam [7:0] ERR_DIMENSION  = 8'h04;
    localparam [7:0] ERR_ALIGNMENT  = 8'h05;
    localparam [7:0] ERR_STRIDE     = 8'h06;
    localparam [7:0] ERR_ADDRESS    = 8'h07;
    localparam [7:0] ERR_RESERVED  = 8'h08;

    localparam [15:0] DESC_VERSION = 16'd1;
    localparam [15:0] DESC_WORDS   = 16'd32;

    // Descriptor word index map (see v1.1 architecture requirements).
    //  0..1 A_BASE, 2..3 B_BASE, 4..5 C_BASE
    //  6..7 NEXT_DESC, 8..9 EXIT_DESC, 10..11 BIAS_BASE
    //  12 CFG, 13 SCALE_Q31, 14 QCFG, 15 M_N, 16 K
    //  17 A_TILE_STRIDE_BYTES, 18 B_TILE_STRIDE_BYTES
    //  19 C_TILE_STRIDE_BYTES, 20 CONF_MARGIN_THRESHOLD
    //  21 DEADLINE_CYCLES, 22 LAYER_ID, 23 DESC_VERSION_LENGTH
    //  24..31 RESERVED and required to be zero in v1.
    reg [31:0] desc_words [0:31];
    reg        frame_active;
    reg [4:0]  expected_index;
    integer i;

    function [31:0] minimum_ab_stride;
        input [15:0] k_value;
        input [1:0] mode;
        integer groups;
        begin
            if (mode == 2'b01)
                groups = (k_value + 1) / 2; // INT8: two K values per 16-bit lane
            else
                groups = (k_value + 3) / 4; // INT4: four K values per 16-bit lane
            minimum_ab_stride = groups * 8; // one 64-bit packed feeder beat
        end
    endfunction

    // Reset and frame assembly/validation.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_active          <= 1'b0;
            expected_index        <= 5'd0;
            descriptor_done       <= 1'b0;
            descriptor_valid      <= 1'b0;
            config_error          <= 1'b0;
            error_code            <= ERR_NONE;

            start_ptr             <= 64'd0;
            front_ptr             <= 64'd0;
            exit_ptr              <= 64'd0;
            weight_base           <= 64'd0;
            output_base           <= 64'd0;
            bias_base             <= 64'd0;
            precision_mode        <= 2'b01;
            scale_m0              <= 32'd0;
            shift_n               <= 5'd0;
            zero_point_z          <= 8'd0;
            conf_thresh           <= 32'd0;
            m_dim                 <= 16'd0;
            n_dim                 <= 16'd0;
            k_dim                 <= 16'd0;
            a_tile_stride_bytes   <= 32'd0;
            b_tile_stride_bytes   <= 32'd0;
            c_tile_stride_bytes   <= 32'd0;
            deadline_cycles       <= 32'd0;
            layer_id              <= 32'd0;
            cfg_flags             <= 6'd0;

            for (i = 0; i < 32; i = i + 1)
                desc_words[i] <= 32'd0;
        end else begin
            // Completion is a one-cycle pulse. Error/valid remain sticky until
            // a new descriptor starts at word 0 or reset is asserted.
            descriptor_done <= 1'b0;

            if (load_descriptor_en) begin
                if (word_index == 5'd0) begin
                    // Start a new frame; no fields are committed until word 31.
                    frame_active     <= 1'b1;
                    expected_index   <= 5'd1;
                    descriptor_valid <= 1'b0;
                    config_error     <= 1'b0;
                    error_code       <= ERR_NONE;
                    desc_words[0]    <= descriptor_word_in;
                end else if (!frame_active || (word_index != expected_index)) begin
                    // Abort a malformed/incomplete descriptor instead of using
                    // a mixture of new and stale words.
                    frame_active     <= 1'b0;
                    descriptor_done  <= 1'b1;
                    descriptor_valid <= 1'b0;
                    config_error     <= 1'b1;
                    error_code       <= ERR_WORD_ORDER;
                end else begin
                    desc_words[word_index] <= descriptor_word_in;
                    expected_index <= expected_index + 1'b1;

                    if (word_index == 5'd31) begin
                        frame_active    <= 1'b0;
                        descriptor_done <= 1'b1;

                        // Validation is done before output registers are updated,
                        // ensuring the last (possibly invalid) frame is atomic.
                        if ((desc_words[23][15:0] != DESC_VERSION) ||
                            (desc_words[23][31:16] != DESC_WORDS)) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_VERSION;
                        end else if ((desc_words[12][1:0] != 2'b01) &&
                                     (desc_words[12][1:0] != 2'b10)) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_PRECISION;
                        end else if ((desc_words[15][15:0] == 16'd0) ||
                                     (desc_words[15][31:16] == 16'd0) ||
                                     (desc_words[16][15:0] == 16'd0) ||
                                     (desc_words[16][31:16] != 16'd0)) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_DIMENSION;
                        end else if ((desc_words[12][31:6] != 26'd0) ||
                                     (desc_words[14][31:13] != 19'd0) ||
                                     (desc_words[20][31:16] != 16'd0) ||
                                     (desc_words[24] != 32'd0) ||
                                     (desc_words[25] != 32'd0) ||
                                     (desc_words[26] != 32'd0) ||
                                     (desc_words[27] != 32'd0) ||
                                     (desc_words[28] != 32'd0) ||
                                     (desc_words[29] != 32'd0) ||
                                     (desc_words[30] != 32'd0) ||
                                     (descriptor_word_in != 32'd0)) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_RESERVED;
                        end else if (({desc_words[1], desc_words[0]} == 64'd0) ||
                                     ({desc_words[3], desc_words[2]} == 64'd0) ||
                                     ({desc_words[5], desc_words[4]} == 64'd0) ||
                                     ((desc_words[12][5] == 1'b1) &&
                                      ({desc_words[11], desc_words[10]} == 64'd0)) ||
                                     ((ADDR_WIDTH == 32) &&
                                      ((desc_words[1]  != 32'd0) ||
                                       (desc_words[3]  != 32'd0) ||
                                       (desc_words[5]  != 32'd0) ||
                                       (desc_words[7]  != 32'd0) ||
                                       (desc_words[9]  != 32'd0) ||
                                       ((desc_words[12][5] == 1'b1) &&
                                        (desc_words[11] != 32'd0))))) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_ADDRESS;
                        end else if ((desc_words[0][2:0] != 3'b000) ||
                                     (desc_words[2][2:0] != 3'b000) ||
                                     (desc_words[4][2:0] != 3'b000) ||
                                     (({desc_words[7], desc_words[6]} != 64'd0) &&
                                      (desc_words[6][6:0] != 7'd0)) ||
                                     (({desc_words[9], desc_words[8]} != 64'd0) &&
                                      (desc_words[8][6:0] != 7'd0)) ||
                                     ((desc_words[12][5] == 1'b1) &&
                                      (desc_words[10][1:0] != 2'b00))) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_ALIGNMENT;
                        end else if ((desc_words[17][2:0] != 3'b000) ||
                                     (desc_words[18][2:0] != 3'b000) ||
                                     (desc_words[19][2:0] != 3'b000) ||
                                     (desc_words[17] < minimum_ab_stride(desc_words[16][15:0], desc_words[12][1:0])) ||
                                     (desc_words[18] < minimum_ab_stride(desc_words[16][15:0], desc_words[12][1:0])) ||
                                     ((desc_words[12][1:0] == 2'b01) && (desc_words[19] < 32'd16)) ||
                                     ((desc_words[12][1:0] == 2'b10) && (desc_words[19] < 32'd8))) begin
                            descriptor_valid <= 1'b0;
                            config_error     <= 1'b1;
                            error_code       <= ERR_STRIDE;
                        end else begin
                            // Commit the whole validated descriptor atomically.
                            start_ptr           <= {desc_words[1], desc_words[0]};
                            weight_base         <= {desc_words[3], desc_words[2]};
                            output_base         <= {desc_words[5], desc_words[4]};
                            front_ptr           <= {desc_words[7], desc_words[6]};
                            exit_ptr             <= {desc_words[9], desc_words[8]};
                            bias_base           <= {desc_words[11], desc_words[10]};
                            cfg_flags            <= desc_words[12][5:0];
                            precision_mode       <= desc_words[12][1:0];
                            scale_m0             <= desc_words[13];
                            zero_point_z         <= desc_words[14][7:0];
                            shift_n              <= desc_words[14][12:8];
                            conf_thresh           <= desc_words[20];
                            m_dim                <= desc_words[15][15:0];
                            n_dim                <= desc_words[15][31:16];
                            k_dim                <= desc_words[16][15:0];
                            a_tile_stride_bytes  <= desc_words[17];
                            b_tile_stride_bytes  <= desc_words[18];
                            c_tile_stride_bytes  <= desc_words[19];
                            deadline_cycles      <= desc_words[21];
                            layer_id             <= desc_words[22];
                            descriptor_valid     <= 1'b1;
                            config_error         <= 1'b0;
                            error_code           <= ERR_NONE;
                        end
                    end
                end
            end
        end
    end

endmodule
