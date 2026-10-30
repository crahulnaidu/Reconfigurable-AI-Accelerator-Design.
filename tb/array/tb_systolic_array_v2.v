`timescale 1ns/1ps
module tb_systolic_array_v2;
    localparam integer K8 = 3;
    localparam integer K4 = 2;

    reg clk, rst_n, advance, acc_clear, acc_enable;
    reg [1:0] precision_mode;
    reg [15:0] act_row_in [0:3];
    reg [3:0] act_row_valid, act_row_last;
    reg [15:0] weight_col_in [0:3];
    reg [3:0] weight_col_valid, weight_col_last;
    wire [127:0] pe_accum_out [0:3][0:3];
    wire [15:0] pe_result_valid;
    wire tile_done, config_error, protocol_error, accum_overflow;

    reg signed [7:0] A0 [0:3][0:2];
    reg signed [7:0] A1 [0:3][0:2];
    reg signed [7:0] B0 [0:2][0:3];
    reg signed [7:0] B1 [0:2][0:3];
    integer exp0 [0:3][0:3];
    integer exp1 [0:3][0:3];
    integer checks, t, r, c, k;
    integer a0, a1, a2, a3, b0, b1, b2, b3;

    systolic_array_v2 dut (
        .clk(clk), .rst_n(rst_n), .advance(advance),
        .acc_clear(acc_clear), .acc_enable(acc_enable),
        .precision_mode(precision_mode),
        .act_row_in(act_row_in), .act_row_valid(act_row_valid), .act_row_last(act_row_last),
        .weight_col_in(weight_col_in), .weight_col_valid(weight_col_valid), .weight_col_last(weight_col_last),
        .pe_accum_out(pe_accum_out), .pe_result_valid(pe_result_valid),
        .tile_done(tile_done), .config_error(config_error),
        .protocol_error(protocol_error), .accum_overflow(accum_overflow)
    );

    always #5 clk = ~clk;

    function [15:0] pack4;
        input integer v0, v1, v2, v3;
        begin pack4 = {v3[3:0], v2[3:0], v1[3:0], v0[3:0]}; end
    endfunction

    task automatic clear_tile(input [1:0] mode);
        begin
            @(negedge clk);
            precision_mode=mode; acc_enable=0; advance=1;
            act_row_valid=0; act_row_last=0; weight_col_valid=0; weight_col_last=0;
            acc_clear=1;
            @(posedge clk); #1;
            @(negedge clk); acc_clear=0; acc_enable=1;
            checks=checks+1;
            $display("PASS: accumulator and mesh pipeline cleared for precision %b", mode);
        end
    endtask

    task automatic drive_idle_cycle;
        begin
            @(negedge clk);
            act_row_valid=0; act_row_last=0; weight_col_valid=0; weight_col_last=0;
            for (r=0; r<4; r=r+1) act_row_in[r]=16'd0;
            for (c=0; c<4; c=c+1) weight_col_in[c]=16'd0;
            @(posedge clk); #1;
        end
    endtask

    task automatic test_global_stall;
        begin
            clear_tile(2'b01);
            @(negedge clk);
            act_row_valid=4'b0001; weight_col_valid=4'b0001;
            act_row_last=0; weight_col_last=0;
            for (r=0; r<4; r=r+1) act_row_in[r]=16'h0000;
            for (c=0; c<4; c=c+1) weight_col_in[c]=16'h0000;
            act_row_in[0]=16'h0001;
            weight_col_in[0]=16'h0001;
            advance=0;
            repeat(2) begin
                @(posedge clk); #1;
                if (pe_accum_out[0][0][31:0] !== 32'd0)
                    $fatal(1, "mesh accumulator changed while advance=0");
            end
            checks=checks+1; $display("PASS: global advance stall freezes mesh and accumulators");
            @(negedge clk); advance=1;
            @(posedge clk); #1;
            if (pe_accum_out[0][0][31:0] !== 32'd1)
                $fatal(1, "mesh did not resume after advance returned");
            @(negedge clk); act_row_valid=0; weight_col_valid=0; acc_enable=0;
            checks=checks+1; $display("PASS: mesh resumes correctly after stall");
        end
    endtask

    task automatic run_int8_tile;
        begin
            clear_tile(2'b01);
            // Feeder skew contract: activation row r is injected r cycles late;
            // weight column c is injected c cycles late.
            for (t=0; t<K8+3; t=t+1) begin
                @(negedge clk);
                act_row_valid=0; act_row_last=0; weight_col_valid=0; weight_col_last=0;
                for (r=0; r<4; r=r+1) begin
                    act_row_in[r]=16'd0;
                    k=t-r;
                    if ((k>=0) && (k<K8)) begin
                        act_row_in[r]={A1[r][k], A0[r][k]};
                        act_row_valid[r]=1'b1;
                        act_row_last[r]=(k==K8-1);
                    end
                end
                for (c=0; c<4; c=c+1) begin
                    weight_col_in[c]=16'd0;
                    k=t-c;
                    if ((k>=0) && (k<K8)) begin
                        weight_col_in[c]={B1[k][c], B0[k][c]};
                        weight_col_valid[c]=1'b1;
                        weight_col_last[c]=(k==K8-1);
                    end
                end
                @(posedge clk); #1;
            end
            repeat(3) drive_idle_cycle();
            if (!tile_done) $fatal(1, "INT8 tile_done was not asserted after mesh drain");
            if (!pe_result_valid[15]) $fatal(1, "bottom-right PE result-valid missing at tile completion");
            checks=checks+1; $display("PASS: INT8 4x4 tile completes after registered wavefront drain");

            if (config_error || protocol_error || accum_overflow)
                $fatal(1, "INT8 array error flags: config=%b protocol=%b overflow=%b", config_error, protocol_error, accum_overflow);

            for (r=0; r<4; r=r+1) begin
                for (c=0; c<4; c=c+1) begin
                    if ($signed(pe_accum_out[r][c][31:0]) !== exp0[r][c])
                        $fatal(1, "INT8 lane0 PE[%0d][%0d] expected %0d got %0d", r,c,exp0[r][c],$signed(pe_accum_out[r][c][31:0]));
                    if ($signed(pe_accum_out[r][c][63:32]) !== exp1[r][c])
                        $fatal(1, "INT8 lane1 PE[%0d][%0d] expected %0d got %0d", r,c,exp1[r][c],$signed(pe_accum_out[r][c][63:32]));
                    if (pe_accum_out[r][c][127:64] !== 64'd0)
                        $fatal(1, "INT8 unused accumulator lanes not zero at PE[%0d][%0d]",r,c);
                    checks=checks+2;
                end
            end
            $display("PASS: all 16 INT8 PE outputs match two-lane signed GEMM reference");
        end
    endtask

    task automatic run_int4_tile;
        begin
            clear_tile(2'b10);
            for (t=0; t<K4+3; t=t+1) begin
                @(negedge clk);
                act_row_valid=0; act_row_last=0; weight_col_valid=0; weight_col_last=0;
                for (r=0; r<4; r=r+1) begin
                    act_row_in[r]=16'd0;
                    k=t-r;
                    if ((k>=0) && (k<K4)) begin
                        if (k==0) begin
                            a0=r+1; a1=-(r+1); a2=r-1; a3=1;
                        end else begin
                            a0=1; a1=1; a2=2; a3=-1;
                        end
                        act_row_in[r]=pack4(a0,a1,a2,a3);
                        act_row_valid[r]=1'b1;
                        act_row_last[r]=(k==K4-1);
                    end
                end
                for (c=0; c<4; c=c+1) begin
                    weight_col_in[c]=16'd0;
                    k=t-c;
                    if ((k>=0) && (k<K4)) begin
                        if (k==0) begin
                            b0=c+1; b1=-1; b2=1; b3=(c%3)-1;
                        end else begin
                            b0=1; b1=c+1; b2=-1; b3=2;
                        end
                        weight_col_in[c]=pack4(b0,b1,b2,b3);
                        weight_col_valid[c]=1'b1;
                        weight_col_last[c]=(k==K4-1);
                    end
                end
                @(posedge clk); #1;
            end
            repeat(3) drive_idle_cycle();
            if (!tile_done) $fatal(1, "INT4 tile_done was not asserted after mesh drain");
            if (config_error || protocol_error || accum_overflow)
                $fatal(1, "INT4 array error flags: config=%b protocol=%b overflow=%b", config_error, protocol_error, accum_overflow);

            for (r=0; r<4; r=r+1) begin
                for (c=0; c<4; c=c+1) begin
                    if ($signed(pe_accum_out[r][c][31:0]) !== ((r+1)*(c+1)+1))
                        $fatal(1, "INT4 lane0 PE[%0d][%0d] mismatch",r,c);
                    if ($signed(pe_accum_out[r][c][63:32]) !== (r+c+2))
                        $fatal(1, "INT4 lane1 PE[%0d][%0d] mismatch",r,c);
                    if ($signed(pe_accum_out[r][c][95:64]) !== (r-3))
                        $fatal(1, "INT4 lane2 PE[%0d][%0d] mismatch",r,c);
                    if ($signed(pe_accum_out[r][c][127:96]) !== ((c%3)-3))
                        $fatal(1, "INT4 lane3 PE[%0d][%0d] mismatch",r,c);
                    checks=checks+4;
                end
            end
            checks=checks+1; $display("PASS: all 16 INT4 PE outputs match four-lane signed GEMM reference");
        end
    endtask

    initial begin
        clk=0; rst_n=0; advance=1; acc_clear=0; acc_enable=0; precision_mode=2'b01;
        act_row_valid=0; act_row_last=0; weight_col_valid=0; weight_col_last=0; checks=0;
        for (r=0; r<4; r=r+1) begin
            for (k=0; k<3; k=k+1) begin A0[r][k]=0; A1[r][k]=0; end
            for (c=0; c<4; c=c+1) begin exp0[r][c]=0; exp1[r][c]=0; end
        end
        // INT8 lane-0 and lane-1 golden matrices.
        A0[0][0]=1; A0[0][1]=2; A0[0][2]=0;
        A0[1][0]=0; A0[1][1]=1; A0[1][2]=2;
        A0[2][0]=1; A0[2][1]=1; A0[2][2]=1;
        A0[3][0]=2; A0[3][1]=0; A0[3][2]=1;
        A1[0][0]=1; A1[0][1]=-1; A1[0][2]=2;
        A1[1][0]=2; A1[1][1]=0;  A1[1][2]=-1;
        A1[2][0]=-1; A1[2][1]=1; A1[2][2]=1;
        A1[3][0]=1; A1[3][1]=2; A1[3][2]=0;

        B0[0][0]=1; B0[0][1]=0; B0[0][2]=2; B0[0][3]=1;
        B0[1][0]=0; B0[1][1]=1; B0[1][2]=1; B0[1][3]=2;
        B0[2][0]=1; B0[2][1]=1; B0[2][2]=0; B0[2][3]=0;
        B1[0][0]=1; B1[0][1]=2; B1[0][2]=0; B1[0][3]=-1;
        B1[1][0]=-1; B1[1][1]=1; B1[1][2]=2; B1[1][3]=0;
        B1[2][0]=2; B1[2][1]=0; B1[2][2]=1; B1[2][3]=1;

        exp0[0][0]=1; exp0[0][1]=2; exp0[0][2]=4; exp0[0][3]=5;
        exp0[1][0]=2; exp0[1][1]=3; exp0[1][2]=1; exp0[1][3]=2;
        exp0[2][0]=2; exp0[2][1]=2; exp0[2][2]=3; exp0[2][3]=3;
        exp0[3][0]=3; exp0[3][1]=1; exp0[3][2]=4; exp0[3][3]=2;
        exp1[0][0]=6; exp1[0][1]=1; exp1[0][2]=0; exp1[0][3]=1;
        exp1[1][0]=0; exp1[1][1]=4; exp1[1][2]=-1; exp1[1][3]=-3;
        exp1[2][0]=0; exp1[2][1]=-1; exp1[2][2]=3; exp1[2][3]=2;
        exp1[3][0]=-1; exp1[3][1]=4; exp1[3][2]=4; exp1[3][3]=-1;

        repeat(2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        checks=checks+1; $display("PASS: systolic array reset");

        test_global_stall();
        run_int8_tile();
        run_int4_tile();

        $display("\nSYSTOLIC ARRAY V2 SUMMARY");
        $display("Checks run: %0d", checks);
        $display("Failures : 0");
        $display("SYSTOLIC ARRAY VERIFICATION PASSED");
        $finish;
    end
endmodule
