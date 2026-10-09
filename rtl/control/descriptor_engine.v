module descriptor_engine(
    input wire clk,
    input wire rst_n,

    input wire load_descriptor_en,
    input wire [31:0] descriptor_word_in,
    input wire [2:0] word_index,

    output reg [31:0] start_ptr,
    output reg [31:0] front_ptr,
    output reg [31:0] exit_ptr,

    output reg [1:0] precision_mode,
    output reg [31:0] scale_m0,
    output reg [4:0] shift_n,
    output reg [7:0] zero_point_z,
    output reg [15:0] conf_thresh
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_ptr      <= 32'h0000_0000;
            front_ptr      <= 32'h0000_0000;
            exit_ptr       <= 32'h0000_0000;
            precision_mode <= 2'b01; // Default INT8
            scale_m0       <= 32'h0000_0000;
            shift_n        <= 5'd0;
            zero_point_z   <= 8'sd0;
            conf_thresh    <= 16'h0000;
        end else if(load_descriptor_en) begin
            case (word_index)
                 3'd0: start_ptr<=descriptor_word_in;
                 3'd1: front_ptr<=descriptor_word_in;
                 3'd2: exit_ptr<=descriptor_word_in;
                 3'd3: begin
                    precision_mode<=descriptor_word_in[1:0];
                    shift_n<=descriptor_word_in[6:2];
                    zero_point_z<=descriptor_word_in[14:7];
                 end
                 3'd4: scale_m0<=descriptor_word_in;
                 3'd5: conf_thresh<=descriptor_word_in[15:0];
                 default: ;
            endcase
        end
    end
endmodule