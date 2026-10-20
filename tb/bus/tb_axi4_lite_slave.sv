`timescale 1ns/1ps

module tb_axi4_lite_slave;
    // ADDR_WIDTH=6 here so the testbench can test an unmapped aligned address
    // (0x20). The normal prototype can use the default ADDR_WIDTH=5.
    localparam integer ADDR_WIDTH = 6;
    localparam integer DATA_WIDTH = 32;
    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    localparam [ADDR_WIDTH-1:0] ADDR_CTRL        = 6'h00;
    localparam [ADDR_WIDTH-1:0] ADDR_STATUS      = 6'h04;
    localparam [ADDR_WIDTH-1:0] ADDR_ROOT_PTR    = 6'h08;
    localparam [ADDR_WIDTH-1:0] ADDR_ZERO_SKIPS  = 6'h0C;
    localparam [ADDR_WIDTH-1:0] ADDR_LATENCY     = 6'h10;
    localparam [ADDR_WIDTH-1:0] ADDR_ERROR_STATUS= 6'h14;
    localparam [ADDR_WIDTH-1:0] ADDR_IRQ_STATUS  = 6'h18;
    localparam [ADDR_WIDTH-1:0] ADDR_IRQ_ENABLE  = 6'h1C;

    reg clk;
    reg rst_n;

    reg  [ADDR_WIDTH-1:0] s_axi_awaddr;
    reg                   s_axi_awvalid;
    wire                  s_axi_awready;

    reg  [DATA_WIDTH-1:0] s_axi_wdata;
    reg  [DATA_WIDTH/8-1:0] s_axi_wstrb;
    reg                   s_axi_wvalid;
    wire                  s_axi_wready;

    wire [1:0] s_axi_bresp;
    wire       s_axi_bvalid;
    reg        s_axi_bready;

    reg  [ADDR_WIDTH-1:0] s_axi_araddr;
    reg                   s_axi_arvalid;
    wire                  s_axi_arready;

    wire [DATA_WIDTH-1:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire       s_axi_rvalid;
    reg        s_axi_rready;

    wire        start_inference;
    wire        soft_reset;
    wire [31:0] root_descriptor_ptr;
    reg         busy;
    reg         inference_complete;
    reg         early_exit_occurred;
    reg [19:0]  total_zero_skips;
    reg [31:0]  total_latency_cycles;
    wire        irq;

    integer start_pulse_count;
    integer reset_pulse_count;
    integer timeout_tb;
    reg start_was_high;
    reg reset_was_high;

    axi4_lite_slave #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .s_axi_awaddr         (s_axi_awaddr),
        .s_axi_awvalid        (s_axi_awvalid),
        .s_axi_awready        (s_axi_awready),
        .s_axi_wdata          (s_axi_wdata),
        .s_axi_wstrb          (s_axi_wstrb),
        .s_axi_wvalid         (s_axi_wvalid),
        .s_axi_wready         (s_axi_wready),
        .s_axi_bresp          (s_axi_bresp),
        .s_axi_bvalid         (s_axi_bvalid),
        .s_axi_bready         (s_axi_bready),
        .s_axi_araddr         (s_axi_araddr),
        .s_axi_arvalid        (s_axi_arvalid),
        .s_axi_arready        (s_axi_arready),
        .s_axi_rdata          (s_axi_rdata),
        .s_axi_rresp          (s_axi_rresp),
        .s_axi_rvalid         (s_axi_rvalid),
        .s_axi_rready         (s_axi_rready),
        .start_inference      (start_inference),
        .soft_reset           (soft_reset),
        .root_descriptor_ptr  (root_descriptor_ptr),
        .busy                 (busy),
        .inference_complete   (inference_complete),
        .early_exit_occurred  (early_exit_occurred),
        .total_zero_skips     (total_zero_skips),
        .total_latency_cycles (total_latency_cycles),
        .irq                  (irq)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Command-pulse monitor.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_pulse_count = 0;
            reset_pulse_count = 0;
            start_was_high    = 1'b0;
            reset_was_high    = 1'b0;
        end else begin
            if (start_inference) begin
                start_pulse_count = start_pulse_count + 1;
                if (start_was_high)
                    $fatal(1, "start_inference high for more than one cycle");
            end
            if (soft_reset) begin
                reset_pulse_count = reset_pulse_count + 1;
                if (reset_was_high)
                    $fatal(1, "soft_reset high for more than one cycle");
            end
            start_was_high = start_inference;
            reset_was_high = soft_reset;
        end
    end

    // Lightweight protocol checker. It checks that master payloads are held
    // while VALID=1/READY=0 and that slave response payloads remain stable while
    // their VALID=1/READY=0. This is portable to Icarus Verilog (no SVA required).
    reg aw_stalled, w_stalled, ar_stalled, b_stalled, r_stalled;
    reg [ADDR_WIDTH-1:0] prev_awaddr, prev_araddr;
    reg [31:0] prev_wdata, prev_rdata;
    reg [3:0] prev_wstrb;
    reg [1:0] prev_bresp, prev_rresp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_stalled <= 1'b0;
            w_stalled  <= 1'b0;
            ar_stalled <= 1'b0;
            b_stalled  <= 1'b0;
            r_stalled  <= 1'b0;
            prev_awaddr <= '0;
            prev_araddr <= '0;
            prev_wdata <= '0;
            prev_wstrb <= '0;
            prev_rdata <= '0;
            prev_bresp <= '0;
            prev_rresp <= '0;
        end else begin
            if (aw_stalled && (!s_axi_awvalid || s_axi_awaddr !== prev_awaddr))
                $fatal(1, "AXI protocol violation: AW payload changed under backpressure");
            if (w_stalled && (!s_axi_wvalid || s_axi_wdata !== prev_wdata || s_axi_wstrb !== prev_wstrb))
                $fatal(1, "AXI protocol violation: W payload changed under backpressure");
            if (ar_stalled && (!s_axi_arvalid || s_axi_araddr !== prev_araddr))
                $fatal(1, "AXI protocol violation: AR payload changed under backpressure");
            if (b_stalled && (!s_axi_bvalid || s_axi_bresp !== prev_bresp))
                $fatal(1, "AXI protocol violation: B response changed under backpressure");
            if (r_stalled && (!s_axi_rvalid || s_axi_rdata !== prev_rdata || s_axi_rresp !== prev_rresp))
                $fatal(1, "AXI protocol violation: R response changed under backpressure");

            aw_stalled <= s_axi_awvalid && !s_axi_awready;
            w_stalled  <= s_axi_wvalid  && !s_axi_wready;
            ar_stalled <= s_axi_arvalid && !s_axi_arready;
            b_stalled  <= s_axi_bvalid  && !s_axi_bready;
            r_stalled  <= s_axi_rvalid  && !s_axi_rready;

            prev_awaddr <= s_axi_awaddr;
            prev_wdata  <= s_axi_wdata;
            prev_wstrb  <= s_axi_wstrb;
            prev_araddr <= s_axi_araddr;
            prev_bresp  <= s_axi_bresp;
            prev_rdata  <= s_axi_rdata;
            prev_rresp  <= s_axi_rresp;
        end
    end

    task automatic send_aw(input [ADDR_WIDTH-1:0] addr);
        integer timeout;
        begin
            @(negedge clk);
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            timeout = 0;
            while (s_axi_awready !== 1'b1 && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (s_axi_awready !== 1'b1) $fatal(1, "Timeout waiting for AWREADY");
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task automatic send_w(input [31:0] data, input [3:0] strb);
        integer timeout;
        begin
            @(negedge clk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strb;
            s_axi_wvalid = 1'b1;
            timeout = 0;
            while (s_axi_wready !== 1'b1 && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (s_axi_wready !== 1'b1) $fatal(1, "Timeout waiting for WREADY");
            @(posedge clk);
            @(negedge clk);
            s_axi_wvalid = 1'b0;
        end
    endtask

    task automatic send_aw_w_together(
        input [ADDR_WIDTH-1:0] addr,
        input [31:0] data,
        input [3:0] strb
    );
        integer timeout;
        begin
            @(negedge clk);
            s_axi_awaddr  = addr;
            s_axi_awvalid = 1'b1;
            s_axi_wdata   = data;
            s_axi_wstrb   = strb;
            s_axi_wvalid  = 1'b1;
            timeout = 0;
            while (!(s_axi_awready === 1'b1 && s_axi_wready === 1'b1) && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (!(s_axi_awready === 1'b1 && s_axi_wready === 1'b1))
                $fatal(1, "Timeout waiting for simultaneous AWREADY/WREADY");
            @(posedge clk);
            @(negedge clk);
            s_axi_awvalid = 1'b0;
            s_axi_wvalid  = 1'b0;
        end
    endtask

    task automatic accept_b(input [1:0] expected_resp);
        integer timeout, k;
        reg [1:0] held_resp;
        begin
            s_axi_bready = 1'b0;
            timeout = 0;
            while (s_axi_bvalid !== 1'b1 && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (s_axi_bvalid !== 1'b1) $fatal(1, "Timeout waiting for BVALID");
            if (s_axi_bresp !== expected_resp)
                $fatal(1, "BRESP mismatch: expected %b got %b", expected_resp, s_axi_bresp);
            held_resp = s_axi_bresp;
            repeat (2) begin
                @(negedge clk);
                if (s_axi_bvalid !== 1'b1 || s_axi_bresp !== held_resp)
                    $fatal(1, "B response was not stable during backpressure");
            end
            s_axi_bready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic write_reg(
        input [ADDR_WIDTH-1:0] addr,
        input [31:0] data,
        input [3:0] strb,
        input integer order_mode, // 0 AW first, 1 W first, 2 simultaneous
        input [1:0] expected_resp
    );
        begin
            case (order_mode)
                0: begin
                    send_aw(addr);
                    repeat (2) @(negedge clk);
                    send_w(data, strb);
                end
                1: begin
                    send_w(data, strb);
                    repeat (2) @(negedge clk);
                    send_aw(addr);
                end
                default: send_aw_w_together(addr, data, strb);
            endcase
            accept_b(expected_resp);
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic read_reg(
        input [ADDR_WIDTH-1:0] addr,
        input [31:0] expected_data,
        input [1:0] expected_resp
    );
        integer timeout;
        reg [31:0] held_data;
        reg [1:0] held_resp;
        begin
            s_axi_rready = 1'b0;
            @(negedge clk);
            s_axi_araddr  = addr;
            s_axi_arvalid = 1'b1;
            timeout = 0;
            while (s_axi_arready !== 1'b1 && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (s_axi_arready !== 1'b1) $fatal(1, "Timeout waiting for ARREADY");
            @(posedge clk);
            @(negedge clk);
            s_axi_arvalid = 1'b0;

            timeout = 0;
            while (s_axi_rvalid !== 1'b1 && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            if (s_axi_rvalid !== 1'b1) $fatal(1, "Timeout waiting for RVALID");
            if (s_axi_rresp !== expected_resp)
                $fatal(1, "RRESP mismatch addr=0x%02h expected=%b actual=%b", addr, expected_resp, s_axi_rresp);
            if (s_axi_rdata !== expected_data)
                $fatal(1, "RDATA mismatch addr=0x%02h expected=0x%08h actual=0x%08h", addr, expected_data, s_axi_rdata);

            held_data = s_axi_rdata;
            held_resp = s_axi_rresp;
            repeat (2) begin
                @(negedge clk);
                if (s_axi_rvalid !== 1'b1 || s_axi_rdata !== held_data || s_axi_rresp !== held_resp)
                    $fatal(1, "R response payload was not stable during backpressure");
            end
            s_axi_rready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            s_axi_rready = 1'b0;
        end
    endtask

    task automatic clear_errors_and_irqs;
        begin
            write_reg(ADDR_ERROR_STATUS, 32'h0000_0007, 4'b0001, 2, RESP_OKAY);
            write_reg(ADDR_IRQ_STATUS,   32'h0000_0007, 4'b0001, 1, RESP_OKAY);
        end
    endtask

    initial begin
        rst_n = 1'b0;
        s_axi_awaddr = '0; s_axi_awvalid = 1'b0;
        s_axi_wdata = '0; s_axi_wstrb = '0; s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b0;
        s_axi_araddr = '0; s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        busy = 1'b0;
        inference_complete = 1'b0;
        early_exit_occurred = 1'b0;
        total_zero_skips = 20'd0;
        total_latency_cycles = 32'd0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("[TEST 1] Reset values and basic ROOT_PTR read/write");
        if (root_descriptor_ptr !== 32'h0) $fatal(1, "ROOT_PTR reset value incorrect");
        read_reg(ADDR_ROOT_PTR, 32'h0000_0000, RESP_OKAY);
        write_reg(ADDR_ROOT_PTR, 32'h1122_3344, 4'b1111, 0, RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'h1122_3344, RESP_OKAY);

        $display("[TEST 2] Partial WSTRB write and W-before-AW");
        write_reg(ADDR_ROOT_PTR, 32'hAABB_CCDD, 4'b0011, 2, RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'h1122_CCDD, RESP_OKAY);
        write_reg(ADDR_ROOT_PTR, 32'hDEAD_BEEF, 4'b1111, 1, RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'hDEAD_BEEF, RESP_OKAY);

        $display("[TEST 3] AW/W VALID payload held while B response backpressures next write");
        // Complete one write but deliberately leave BREADY low.
        send_aw(ADDR_ROOT_PTR);
        send_w(32'h0102_0304, 4'b1111);
        timeout_tb = 0;
        while (s_axi_bvalid !== 1'b1 && timeout_tb < 100) begin
            @(negedge clk);
            timeout_tb = timeout_tb + 1;
        end
        if (s_axi_bvalid !== 1'b1) $fatal(1, "Timeout waiting for first BVALID in backpressure test");
        if (s_axi_bresp !== RESP_OKAY) $fatal(1, "Unexpected BRESP in backpressure test");

        // Present the next write while the first response is stalled. The
        // slave must hold READY low, and the master must hold its payload.
        s_axi_awaddr  = ADDR_ROOT_PTR;
        s_axi_awvalid = 1'b1;
        s_axi_wdata   = 32'h5566_7788;
        s_axi_wstrb   = 4'b1111;
        s_axi_wvalid  = 1'b1;
        repeat (2) begin
            @(negedge clk);
            if (s_axi_bvalid !== 1'b1 || s_axi_bresp !== RESP_OKAY)
                $fatal(1, "First B response not held under backpressure");
            if (s_axi_awready !== 1'b0 || s_axi_wready !== 1'b0)
                $fatal(1, "AWREADY/WREADY should be low while B response is outstanding");
            if (s_axi_awaddr !== ADDR_ROOT_PTR || s_axi_wdata !== 32'h5566_7788 || s_axi_wstrb !== 4'b1111)
                $fatal(1, "Master request payload changed during backpressure test");
        end
        s_axi_bready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        s_axi_bready = 1'b0;
        if (s_axi_awready !== 1'b1 || s_axi_wready !== 1'b1)
            $fatal(1, "AWREADY/WREADY did not recover after B response acceptance");
        @(posedge clk); // second AW and W handshake
        @(negedge clk);
        s_axi_awvalid = 1'b0;
        s_axi_wvalid  = 1'b0;
        accept_b(RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'h5566_7788, RESP_OKAY);

        $display("[TEST 4] Normal START pulse while idle");
        write_reg(ADDR_CTRL, 32'h1, 4'b0001, 2, RESP_OKAY);
        if (start_pulse_count != 1) $fatal(1, "Expected one start pulse, saw %0d", start_pulse_count);

        $display("[TEST 5] START while busy must be rejected");
        busy = 1'b1;
        write_reg(ADDR_CTRL, 32'h1, 4'b0001, 0, RESP_SLVERR);
        if (start_pulse_count != 1) $fatal(1, "START pulse emitted while busy");
        read_reg(ADDR_ERROR_STATUS, 32'h0000_0002, RESP_OKAY);
        clear_errors_and_irqs();
        busy = 1'b0;

        $display("[TEST 6] START and SOFT_RESET together: reset wins, SLVERR");
        write_reg(ADDR_CTRL, 32'h3, 4'b0001, 1, RESP_SLVERR);
        if (start_pulse_count != 1) $fatal(1, "START should be suppressed for conflicting command");
        if (reset_pulse_count != 1) $fatal(1, "SOFT_RESET should pulse for conflicting command");
        read_reg(ADDR_ERROR_STATUS, 32'h0000_0004, RESP_OKAY);
        clear_errors_and_irqs();

        $display("[TEST 7] SOFT_RESET alone produces a pulse");
        write_reg(ADDR_CTRL, 32'h2, 4'b0001, 2, RESP_OKAY);
        if (reset_pulse_count != 2) $fatal(1, "Expected second reset pulse");

        $display("[TEST 8] Configure interrupts and create completion/early-exit events");
        write_reg(ADDR_IRQ_ENABLE, 32'h7, 4'b0001, 2, RESP_OKAY);
        read_reg(ADDR_IRQ_ENABLE, 32'h7, RESP_OKAY);
        @(negedge clk); inference_complete = 1'b1;
        @(negedge clk); inference_complete = 1'b0;
        @(negedge clk); early_exit_occurred = 1'b1;
        @(negedge clk); early_exit_occurred = 1'b0;
        repeat (2) @(negedge clk);
        // STATUS: bit0 busy=0, bit1 completion sticky=1, bit2 early-exit sticky=1,
        // bit3 error indicator=0, bit4 enabled IRQ pending=1.
        read_reg(ADDR_STATUS, 32'h0000_0016, RESP_OKAY);
        read_reg(ADDR_IRQ_STATUS, 32'h0000_0003, RESP_OKAY);
        if (irq !== 1'b1) $fatal(1, "IRQ should be asserted for enabled events");

        $display("[TEST 9] W1C clears sticky status and interrupt flags");
        write_reg(ADDR_STATUS, 32'h6, 4'b0001, 2, RESP_OKAY);
        read_reg(ADDR_STATUS, 32'h0000_0010, RESP_OKAY);
        write_reg(ADDR_IRQ_STATUS, 32'h3, 4'b0001, 2, RESP_OKAY);
        read_reg(ADDR_IRQ_STATUS, 32'h0000_0000, RESP_OKAY);
        if (irq !== 1'b0) $fatal(1, "IRQ should deassert after pending bits are cleared");

        $display("[TEST 10] Status counters read correctly");
        busy = 1'b1;
        total_zero_skips = 20'hABCDE;
        total_latency_cycles = 32'h1234_5678;
        read_reg(ADDR_STATUS, 32'h0000_0001, RESP_OKAY);
        read_reg(ADDR_ZERO_SKIPS, 32'h000A_BCDE, RESP_OKAY);
        read_reg(ADDR_LATENCY, 32'h1234_5678, RESP_OKAY);
        busy = 1'b0;

        $display("[TEST 11] Write to read-only ZERO_SKIPS sets error and IRQ event");
        write_reg(ADDR_ZERO_SKIPS, 32'h1, 4'b1111, 2, RESP_SLVERR);
        read_reg(ADDR_ERROR_STATUS, 32'h0000_0001, RESP_OKAY);
        read_reg(ADDR_IRQ_STATUS, 32'h0000_0004, RESP_OKAY);
        if (irq !== 1'b1) $fatal(1, "Error IRQ should be asserted");
        clear_errors_and_irqs();
        if (irq !== 1'b0) $fatal(1, "IRQ should clear after W1C");

        $display("[TEST 12] Unaligned and unmapped accesses are rejected");
        write_reg(ADDR_ROOT_PTR + 1, 32'h0, 4'b1111, 2, RESP_SLVERR);
        read_reg(ADDR_ROOT_PTR + 1, 32'h0, RESP_SLVERR);
        write_reg(6'h20, 32'h0, 4'b1111, 2, RESP_SLVERR);
        read_reg(6'h20, 32'h0, RESP_SLVERR);
        read_reg(ADDR_ERROR_STATUS, 32'h0000_0001, RESP_OKAY);
        clear_errors_and_irqs();

        $display("[TEST 13] WSTRB=0 does not change ROOT_PTR");
        write_reg(ADDR_ROOT_PTR, 32'h0000_0000, 4'b0000, 2, RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'h5566_7788, RESP_OKAY);


        $display("[TEST 14] Reset clears a partially accepted AW channel");
        send_aw(ADDR_ROOT_PTR);
        @(negedge clk); rst_n = 1'b0;
        repeat (2) @(negedge clk);
        if (s_axi_bvalid !== 1'b0 || s_axi_rvalid !== 1'b0)
            $fatal(1, "Response valid was not cleared by reset");
        rst_n = 1'b1;
        repeat (2) @(negedge clk);
        if (root_descriptor_ptr !== 32'h0) $fatal(1, "ROOT_PTR not reset");
        write_reg(ADDR_ROOT_PTR, 32'hCAFE_BABE, 4'b1111, 2, RESP_OKAY);
        read_reg(ADDR_ROOT_PTR, 32'hCAFE_BABE, RESP_OKAY);

        $display("--------------------------------------------------");
        $display("PASS: all AXI4-Lite prototype tests passed.");
        $display("Note: PASS is printed only after all checks in this testbench succeed.");
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "Global testbench timeout");
    end

endmodule
