`timescale 1ns/1ps
module tb_phase2_accelerator_core_v2;
    reg clk, rst_n;
    reg start_inference;
    reg [63:0] root_descriptor_ptr;
    reg global_early_exit_enable;
    wire descriptor_fetch_start;
    wire [63:0] active_descriptor_ptr;
    reg descriptor_word_valid;
    wire descriptor_word_ready;
    reg [4:0] descriptor_word_index;
    reg [31:0] descriptor_word_data;

    wire act_addr_valid; reg act_addr_ready; wire [31:0] act_addr;
    wire act_agu_busy, act_agu_done;
    wire weight_addr_valid; reg weight_addr_ready; wire [31:0] weight_addr;
    wire weight_agu_busy, weight_agu_done;

    reg act_dma_write_valid; wire act_dma_write_ready;
    reg [7:0] act_dma_write_addr; reg [63:0] act_dma_write_data;
    reg act_dma_commit; wire act_dma_commit_ready; wire act_prefetch_complete;
    reg act_bank_swap_req; wire act_bank_swap_ack, act_bank_swap_rejected, act_active_bank;

    reg weight_dma_write_valid; wire weight_dma_write_ready;
    reg [7:0] weight_dma_write_addr; reg [63:0] weight_dma_write_data;
    reg weight_dma_commit; wire weight_dma_commit_ready; wire weight_prefetch_complete;
    reg weight_bank_swap_req; wire weight_bank_swap_ack, weight_bank_swap_rejected, weight_active_bank;
    wire banks_ready;

    wire tile_word_read_req, tile_word_read_ready;
    wire [7:0] tile_word_read_addr;
    wire tile_word_read_last;
    reg array_advance;

    reg confidence_done, early_exit_trigger; wire confidence_eval_start;
    reg [15:0] postproc_result_ready; wire [15:0] postproc_result_valid;
    wire [15:0] postproc_result_data [0:3][0:3];
    wire postproc_tile_done; wire [31:0] saturation_count;
    reg writeback_done; wire output_write_start;

    wire [63:0] a_base,b_base,c_base;
    wire [15:0] m_dim,n_dim,k_dim,k_groups;
    wire [31:0] a_tile_stride_bytes,b_tile_stride_bytes,c_tile_stride_bytes;
    wire [1:0] precision_mode; wire [31:0] scale_m0;
    wire [4:0] shift_n; wire [7:0] zero_point_z;
    wire [31:0] confidence_threshold, deadline_cycles,layer_id; wire [5:0] cfg_flags;

    wire [127:0] pe_accum_out [0:3][0:3];
    wire [15:0] pe_result_valid; wire array_tile_done,array_config_error,array_protocol_error,accum_overflow;
    wire [31:0] zero_skip_count;
    reg external_engine_error; reg [7:0] external_engine_error_code;
    wire busy,inference_complete,early_exit_occurred,error; wire [7:0] error_code;
    wire layer_start;

    reg [31:0] desc [0:31];
    reg signed [7:0] A [0:3][0:3];
    reg signed [7:0] B [0:3][0:3];
    integer checks, i, r, c, g;
    integer act_addr_count, weight_addr_count, tile_read_count;
    reg addr_mismatch, tile_read_mismatch, tile_last_mismatch;
    reg [63:0] a_word, b_word;

    phase2_accelerator_core_v2 dut (
        .clk(clk), .rst_n(rst_n),
        .start_inference(start_inference), .root_descriptor_ptr(root_descriptor_ptr),
        .global_early_exit_enable(global_early_exit_enable),
        .descriptor_fetch_start(descriptor_fetch_start), .active_descriptor_ptr(active_descriptor_ptr),
        .descriptor_word_valid(descriptor_word_valid), .descriptor_word_ready(descriptor_word_ready),
        .descriptor_word_index(descriptor_word_index), .descriptor_word_data(descriptor_word_data),
        .act_addr_valid(act_addr_valid), .act_addr_ready(act_addr_ready), .act_addr(act_addr),
        .act_agu_busy(act_agu_busy), .act_agu_done(act_agu_done),
        .weight_addr_valid(weight_addr_valid), .weight_addr_ready(weight_addr_ready),
        .weight_addr(weight_addr), .weight_agu_busy(weight_agu_busy), .weight_agu_done(weight_agu_done),
        .act_dma_write_valid(act_dma_write_valid), .act_dma_write_ready(act_dma_write_ready),
        .act_dma_write_addr(act_dma_write_addr), .act_dma_write_data(act_dma_write_data),
        .act_dma_commit(act_dma_commit), .act_dma_commit_ready(act_dma_commit_ready),
        .act_prefetch_complete(act_prefetch_complete), .act_bank_swap_req(act_bank_swap_req),
        .act_bank_swap_ack(act_bank_swap_ack), .act_bank_swap_rejected(act_bank_swap_rejected),
        .act_active_bank(act_active_bank),
        .weight_dma_write_valid(weight_dma_write_valid), .weight_dma_write_ready(weight_dma_write_ready),
        .weight_dma_write_addr(weight_dma_write_addr), .weight_dma_write_data(weight_dma_write_data),
        .weight_dma_commit(weight_dma_commit), .weight_dma_commit_ready(weight_dma_commit_ready),
        .weight_prefetch_complete(weight_prefetch_complete), .weight_bank_swap_req(weight_bank_swap_req),
        .weight_bank_swap_ack(weight_bank_swap_ack), .weight_bank_swap_rejected(weight_bank_swap_rejected),
        .weight_active_bank(weight_active_bank), .banks_ready(banks_ready),
        .tile_word_read_req(tile_word_read_req), .tile_word_read_ready(tile_word_read_ready),
        .tile_word_read_addr(tile_word_read_addr), .tile_word_read_last(tile_word_read_last),
        .array_advance(array_advance),
        .confidence_done(confidence_done), .early_exit_trigger(early_exit_trigger),
        .confidence_eval_start(confidence_eval_start),
        .postproc_result_ready(postproc_result_ready), .postproc_result_valid(postproc_result_valid),
        .postproc_result_data(postproc_result_data), .postproc_tile_done(postproc_tile_done),
        .saturation_count(saturation_count), .writeback_done(writeback_done),
        .output_write_start(output_write_start),
        .a_base(a_base), .b_base(b_base), .c_base(c_base), .m_dim(m_dim), .n_dim(n_dim),
        .k_dim(k_dim), .k_groups(k_groups), .a_tile_stride_bytes(a_tile_stride_bytes),
        .b_tile_stride_bytes(b_tile_stride_bytes), .c_tile_stride_bytes(c_tile_stride_bytes),
        .precision_mode(precision_mode), .scale_m0(scale_m0), .shift_n(shift_n),
        .zero_point_z(zero_point_z), .confidence_threshold(confidence_threshold),
        .deadline_cycles(deadline_cycles), .layer_id(layer_id),
        .cfg_flags(cfg_flags), .pe_accum_out(pe_accum_out), .pe_result_valid(pe_result_valid),
        .array_tile_done(array_tile_done), .array_config_error(array_config_error),
        .array_protocol_error(array_protocol_error), .accum_overflow(accum_overflow),
        .zero_skip_count(zero_skip_count),
        .external_engine_error(external_engine_error), .external_engine_error_code(external_engine_error_code),
        .busy(busy), .inference_complete(inference_complete), .early_exit_occurred(early_exit_occurred),
        .error(error), .error_code(error_code), .layer_start(layer_start)
    );

    always #5 clk=~clk;

    always @(posedge clk) begin
        if (rst_n) begin
            if (act_addr_valid && act_addr_ready) begin
                if (act_addr_count==0 && act_addr!==32'h0000_1000) addr_mismatch=1;
                if (act_addr_count==1 && act_addr!==32'h0000_1008) addr_mismatch=1;
                act_addr_count=act_addr_count+1;
            end
            if (weight_addr_valid && weight_addr_ready) begin
                if (weight_addr_count==0 && weight_addr!==32'h0000_2000) addr_mismatch=1;
                if (weight_addr_count==1 && weight_addr!==32'h0000_2008) addr_mismatch=1;
                weight_addr_count=weight_addr_count+1;
            end
            if (tile_word_read_req && tile_word_read_ready) begin
                if (tile_word_read_addr !== tile_read_count[7:0]) tile_read_mismatch=1;
                if (tile_word_read_last !== (tile_read_count==1)) tile_last_mismatch=1;
                tile_read_count=tile_read_count+1;
            end
        end
    end

    task check;
        input condition;
        input [8*120-1:0] message;
        begin
            checks=checks+1;
            if (condition !== 1'b1) begin
                $display("FAIL: %0s",message);
                $fatal(1,"Phase 2 integration assertion failed");
            end else $display("PASS: %0s",message);
        end
    endtask

    task build_descriptor;
        begin
            for (i=0;i<32;i=i+1) desc[i]=0;
            desc[0]=32'h0000_1000; desc[2]=32'h0000_2000; desc[4]=32'h0000_3000;
            desc[12]=32'h0000_0005; // INT8 + CFG bit 2 zero-bypass enable
            desc[13]=32'd1;         // Identity scale for this integer smoke test
            desc[14]=32'd0;         // Shift=0, zero-point=0
            desc[15]=32'h0004_0004; // M=4, N=4
            desc[16]=32'd4;         // K=4 -> 2 packed INT8 K-groups
            desc[17]=32'd16; desc[18]=32'd16; desc[19]=32'd16;
            desc[20]=32'd0; desc[21]=32'd10000; desc[22]=32'd9;
            desc[23]=32'h0020_0001; // length=32, version=1
        end
    endtask

    task send_descriptor;
        begin
            for (i=0;i<32;i=i+1) begin
                @(negedge clk);
                while (!descriptor_word_ready) @(negedge clk);
                descriptor_word_valid=1;
                descriptor_word_index=i[4:0];
                descriptor_word_data=desc[i];
                @(posedge clk); #1;
            end
            @(negedge clk);
            descriptor_word_valid=0; descriptor_word_index=0; descriptor_word_data=0;
        end
    endtask

    task write_bank_words;
        input integer group_index;
        input [63:0] aw;
        input [63:0] bw;
        begin
            @(negedge clk);
            act_dma_write_valid=1; act_dma_write_addr=group_index[7:0]; act_dma_write_data=aw;
            weight_dma_write_valid=1; weight_dma_write_addr=group_index[7:0]; weight_dma_write_data=bw;
            @(posedge clk); #1;
            check(act_dma_write_ready && weight_dma_write_ready,"activation and weight DMA writes accepted into inactive banks");
            @(negedge clk);
            act_dma_write_valid=0; weight_dma_write_valid=0;
        end
    endtask

    task commit_and_swap_banks;
        begin
            @(negedge clk); act_dma_commit=1; weight_dma_commit=1;
            @(posedge clk); #1;
            check(act_prefetch_complete && weight_prefetch_complete,"both scratchpad banks committed after DMA prefetch");
            @(negedge clk); act_dma_commit=0; weight_dma_commit=0;
            act_bank_swap_req=1; weight_bank_swap_req=1;
            @(posedge clk); #1;
            check(act_bank_swap_ack && weight_bank_swap_ack,"both scratchpad ownership swaps acknowledged");
            check(act_active_bank==1 && weight_active_bank==1,"newly filled banks become active for compute");
            @(negedge clk); act_bank_swap_req=0; weight_bank_swap_req=0;
            wait(banks_ready);
            #1; check(banks_ready,"paired activation/weight banks reported ready to compute");
        end
    endtask

    initial begin
        #500000;
        $display("FAIL: Phase 2 integration testbench timed out");
        $fatal(1,"Day 9 integration timeout");
    end

    initial begin
        clk=0; rst_n=0; start_inference=0; root_descriptor_ptr=64'h1000;
        global_early_exit_enable=0; descriptor_word_valid=0; descriptor_word_index=0; descriptor_word_data=0;
        act_addr_ready=1; weight_addr_ready=1;
        act_dma_write_valid=0; act_dma_write_addr=0; act_dma_write_data=0; act_dma_commit=0; act_bank_swap_req=0;
        weight_dma_write_valid=0; weight_dma_write_addr=0; weight_dma_write_data=0; weight_dma_commit=0; weight_bank_swap_req=0;
        array_advance=1;
        confidence_done=0; early_exit_trigger=0; postproc_result_ready=0; writeback_done=0;
        external_engine_error=0; external_engine_error_code=0;
        checks=0; act_addr_count=0; weight_addr_count=0; tile_read_count=0;
        addr_mismatch=0; tile_read_mismatch=0; tile_last_mismatch=0;

        // Integer matrices used by the golden reference C = A*B.
        A[0][0]=1; A[0][1]=2; A[0][2]=3; A[0][3]=4;
        A[1][0]=2; A[1][1]=1; A[1][2]=0; A[1][3]=1;
        A[2][0]=0; A[2][1]=-1; A[2][2]=0; A[2][3]=0;
        A[3][0]=0; A[3][1]=1; A[3][2]=1; A[3][3]=2;
        B[0][0]=1; B[0][1]=2; B[0][2]=0; B[0][3]=1;
        B[1][0]=0; B[1][1]=1; B[1][2]=1; B[1][3]=0;
        B[2][0]=2; B[2][1]=0; B[2][2]=1; B[2][3]=1;
        B[3][0]=1; B[3][1]=1; B[3][2]=0; B[3][3]=2;
        build_descriptor();

        repeat(2) @(posedge clk);
        @(negedge clk); rst_n=1;
        @(posedge clk); #1;
        check(!busy && !error && !inference_complete,"reset leaves integrated core idle");

        @(negedge clk); start_inference=1;
        @(posedge clk); #1;
        @(negedge clk); start_inference=0;
        check(descriptor_fetch_start && active_descriptor_ptr==root_descriptor_ptr,
              "controller START captures root descriptor pointer and requests descriptor fetch");

        send_descriptor();
        wait(layer_start); #1;
        check(m_dim==4 && n_dim==4 && k_dim==4 && k_groups==2,"valid 4x4 INT8 descriptor decoded with two packed K-groups");
        check(precision_mode==2'b01 && cfg_flags[2] &&
              a_base==64'h1000 && b_base==64'h2000 && c_base==64'h3000,
              "descriptor precision, zero-bypass enable and tensor base addresses reach integrated core");
        check(confidence_threshold==0 && deadline_cycles==10000 && layer_id==9,
              "threshold, deadline and layer metadata exposed to controller interface");

        // Verify AGU address generation. A and B are tile-major packed:
        // one 64-bit word per K-group, each containing 4 row or 4 column vectors.
        wait(act_agu_done && weight_agu_done);
        #1;
        check(act_addr_count==2 && weight_addr_count==2 && !addr_mismatch,
              "activation and transposed-weight AGUs issue the two expected 64-bit K-group addresses");

        // Pack two consecutive INT8 K values into each 16-bit row/column vector.
        for (g=0;g<2;g=g+1) begin
            a_word=64'd0; b_word=64'd0;
            for (r=0;r<4;r=r+1)
                a_word[16*r +: 16]={A[r][2*g+1],A[r][2*g]};
            for (c=0;c<4;c=c+1)
                b_word[16*c +: 16]={B[2*g+1][c],B[2*g][c]};
            write_bank_words(g,a_word,b_word);
        end
        commit_and_swap_banks();

        // The integrated one-tile scheduler now issues paired K-group reads
        // internally after both AGUs finish and both scratchpad swaps are acked.
        // The response bridge and feeder preserve paired words through the mesh.
        wait(postproc_tile_done);
        #1;
        check(array_tile_done && !array_config_error && !array_protocol_error && !accum_overflow,
              "registered systolic mesh completes with no configuration/protocol/overflow errors");
        check(postproc_result_valid==16'hffff,"post-processor captures all sixteen PE results");
        check(tile_read_count==2 && !tile_read_mismatch && !tile_last_mismatch,
              "internal tile scheduler issued K-group addresses 0 and 1 with last on group 1");
        check(saturation_count==0,"no output saturation in the selected numerical test");
        check(zero_skip_count==32'd35,
              "descriptor CFG bit 2 enables per-lane zero bypass and reports 35 skipped products");

        check(postproc_result_data[0][0][7:0]==8'd11 && postproc_result_data[0][1][7:0]==8'd8 &&
              postproc_result_data[0][2][7:0]==8'd5 && postproc_result_data[0][3][7:0]==8'd12,
              "post-processed row 0 matches software GEMM reference");
        check(postproc_result_data[1][0][7:0]==8'd3 && postproc_result_data[1][1][7:0]==8'd6 &&
              postproc_result_data[1][2][7:0]==8'd1 && postproc_result_data[1][3][7:0]==8'd4,
              "post-processed row 1 matches software GEMM reference");
        check(postproc_result_data[2][0]==16'h0000 && postproc_result_data[2][1]==16'hffff &&
              postproc_result_data[2][2]==16'hffff && postproc_result_data[2][3]==16'h0000,
              "post-processed signed row 2 matches software GEMM reference and sign extension");
        check(postproc_result_data[3][0][7:0]==8'd4 && postproc_result_data[3][1][7:0]==8'd3 &&
              postproc_result_data[3][2][7:0]==8'd2 && postproc_result_data[3][3][7:0]==8'd5,
              "post-processed row 3 matches software GEMM reference");

        // Simulate output DMA consuming all sixteen result records.
        wait(output_write_start);
        #1; check(busy && !inference_complete,"sequencer starts writeback only after all PE results are post-processed");
        @(negedge clk); postproc_result_ready=16'hffff;
        @(posedge clk); #1;
        check(postproc_result_valid==16'h0000,
              "output writer accepts all sixteen result records before writeback completion");
        @(negedge clk); writeback_done=1;
        @(posedge clk); #1;
        @(negedge clk); writeback_done=0; postproc_result_ready=0;
        wait(inference_complete); #1;
        check(!busy && !error && !early_exit_occurred,"inference completes after successful output writeback");

        $display("");
        $display("PHASE 2 INTEGRATION TEST SUMMARY");
        $display("Checks run: %0d",checks);
        $display("Failures : 0");
        $display("PHASE 2 INTEGRATION VERIFICATION PASSED");
        $finish;
    end
endmodule
