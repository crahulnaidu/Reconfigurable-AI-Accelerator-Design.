`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// AXI4-Lite slave register interface for a prototype DNN accelerator.
//
// CLOCKING:
//   * clk is the common clock for this slave and every status/control signal
//     connected to it. Synchronize signals from other clock domains externally.
//   * rst_n is an active-low asynchronous reset for this interface.
//
// DATA WIDTH:
//   * This prototype intentionally supports DATA_WIDTH == 32 only.
//   * ADDR_WIDTH must be >= 5 to address the 0x00..0x1C register map.
//
// Write transaction behavior:
//   * AW and W are accepted independently and each is captured only on
//     VALID && READY. One write response may be outstanding at a time.
//   * START (CTRL bit 0) while busy is rejected with SLVERR; no start pulse.
//   * If START and SOFT_RESET (CTRL bits 0 and 1) are both written as 1,
//     SOFT_RESET takes priority, START is suppressed, and BRESP is SLVERR.
//     The soft_reset pulse is still issued so the reset request is honored.
//   * start_inference and soft_reset are one-clock-cycle pulses.
//   * WSTRB is honored for ROOT_PTR; CTRL/status/control registers use byte 0.
//
// Register map (byte addresses; aligned 32-bit accesses):
//   0x00 CTRL        R: current command pulse outputs (normally 0)
//                    W bit 0: start inference; bit 1: soft reset
//   0x04 STATUS      R bit 0: busy (live)
//                    R bit 1: inference complete (sticky)
//                    R bit 2: early exit occurred (sticky)
//                    R bit 3: any ERROR_STATUS bit set
//                    R bit 4: enabled interrupt pending
//                    W1C bits 1 and 2 clear sticky completion/early-exit
//   0x08 ROOT_PTR    R/W 32-bit root descriptor pointer; byte strobes supported
//   0x0C ZERO_SKIPS  R 20-bit total_zero_skips
//   0x10 LATENCY     R 32-bit total_latency_cycles
//   0x14 ERROR_STATUS R/W1C: bit 0 bad/unsupported access;
//                          bit 1 START while busy;
//                          bit 2 START and SOFT_RESET requested together
//   0x18 IRQ_STATUS  R/W1C: bit 0 completion event; bit 1 early-exit event;
//                          bit 2 error event
//   0x1C IRQ_ENABLE  R/W: bits 0..2 enable the corresponding IRQ_STATUS sources
//
// All sticky bits set in a cycle take priority over a simultaneous W1C clear.
// This module reports bus/command errors. It has no accelerator-internal error
// input yet; that can be added when the sequencer exposes a defined error signal.
// This module does not implement partial-reconfiguration isolation.
// -----------------------------------------------------------------------------

module axi4_lite_slave #(
    parameter integer ADDR_WIDTH = 5,
    parameter integer DATA_WIDTH = 32
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // AXI4-Lite Write Address Channel
    input  wire [ADDR_WIDTH-1:0]        s_axi_awaddr,
    input  wire                         s_axi_awvalid,
    output reg                          s_axi_awready,

    // AXI4-Lite Write Data Channel
    input  wire [DATA_WIDTH-1:0]        s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]      s_axi_wstrb,
    input  wire                         s_axi_wvalid,
    output reg                          s_axi_wready,

    // AXI4-Lite Write Response Channel
    output reg  [1:0]                   s_axi_bresp,
    output reg                          s_axi_bvalid,
    input  wire                         s_axi_bready,

    // AXI4-Lite Read Address Channel
    input  wire [ADDR_WIDTH-1:0]        s_axi_araddr,
    input  wire                         s_axi_arvalid,
    output reg                          s_axi_arready,

    // AXI4-Lite Read Data Channel
    output reg  [DATA_WIDTH-1:0]        s_axi_rdata,
    output reg  [1:0]                   s_axi_rresp,
    output reg                          s_axi_rvalid,
    input  wire                         s_axi_rready,

    // Accelerator control outputs
    output reg                          start_inference,
    output reg                          soft_reset,
    output reg  [31:0]                  root_descriptor_ptr,

    // Accelerator status inputs: synchronous to clk
    input  wire                         busy,
    input  wire                         inference_complete,
    input  wire                         early_exit_occurred,
    input  wire [19:0]                  total_zero_skips,
    input  wire [31:0]                  total_latency_cycles,

    // Active-high, level-sensitive interrupt output
    output wire                         irq
);

    localparam integer STRB_WIDTH = DATA_WIDTH / 8;

    localparam [ADDR_WIDTH-1:0] ADDR_CTRL        = 5'h00;
    localparam [ADDR_WIDTH-1:0] ADDR_STATUS      = 5'h04;
    localparam [ADDR_WIDTH-1:0] ADDR_ROOT_PTR    = 5'h08;
    localparam [ADDR_WIDTH-1:0] ADDR_ZERO_SKIPS  = 5'h0C;
    localparam [ADDR_WIDTH-1:0] ADDR_LATENCY     = 5'h10;
    localparam [ADDR_WIDTH-1:0] ADDR_ERROR_STATUS= 5'h14;
    localparam [ADDR_WIDTH-1:0] ADDR_IRQ_STATUS  = 5'h18;
    localparam [ADDR_WIDTH-1:0] ADDR_IRQ_ENABLE  = 5'h1C;

    localparam [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam [1:0] AXI_RESP_SLVERR = 2'b10;

    // ERROR_STATUS bits
    localparam integer ERR_BAD_ACCESS       = 0;
    localparam integer ERR_START_WHILE_BUSY = 1;
    localparam integer ERR_CTRL_CONFLICT    = 2;

    // IRQ_STATUS bits
    localparam integer IRQ_COMPLETION = 0;
    localparam integer IRQ_EARLY_EXIT = 1;
    localparam integer IRQ_ERROR      = 2;

    reg [ADDR_WIDTH-1:0]   awaddr_hold;
    reg [DATA_WIDTH-1:0]   wdata_hold;
    reg [STRB_WIDTH-1:0]   wstrb_hold;
    reg                    aw_pending;
    reg                    w_pending;

    reg [2:0] error_status;
    reg [2:0] irq_status;
    reg [2:0] irq_enable;
    reg       completion_sticky;
    reg       early_exit_sticky;
    reg       inference_complete_d;
    reg       early_exit_d;

    wire aw_handshake;
    wire w_handshake;
    wire ar_handshake;
    wire write_commit;
    wire completion_event;
    wire early_exit_event;
    wire read_access_error;
    wire [2:0] write_error_mask;
    wire [2:0] error_set_mask;
    wire [2:0] error_clear_mask;
    wire [2:0] irq_clear_mask;
    wire [2:0] irq_set_mask;
    wire clear_completion_sticky;
    wire clear_early_exit_sticky;

    // READY depends only on interface state (not directly on VALID).
    // READY is forced low while reset is asserted.
    always @* begin
        s_axi_awready = rst_n && !aw_pending && !s_axi_bvalid;
        s_axi_wready  = rst_n && !w_pending  && !s_axi_bvalid;
        s_axi_arready = rst_n && !s_axi_rvalid;
    end

    assign aw_handshake = s_axi_awvalid && s_axi_awready;
    assign w_handshake  = s_axi_wvalid  && s_axi_wready;
    assign ar_handshake = s_axi_arvalid && s_axi_arready;
    assign write_commit = aw_pending && w_pending && !s_axi_bvalid;

    assign completion_event = inference_complete && !inference_complete_d;
    assign early_exit_event = early_exit_occurred && !early_exit_d;

    // Classify unsupported/unaligned read addresses for both response and
    // sticky error reporting.
    reg read_addr_is_valid;
    always @* begin
        read_addr_is_valid = 1'b1;
        if (s_axi_araddr[1:0] != 2'b00) begin
            read_addr_is_valid = 1'b0;
        end else begin
            case (s_axi_araddr)
                ADDR_CTRL,
                ADDR_STATUS,
                ADDR_ROOT_PTR,
                ADDR_ZERO_SKIPS,
                ADDR_LATENCY,
                ADDR_ERROR_STATUS,
                ADDR_IRQ_STATUS,
                ADDR_IRQ_ENABLE: read_addr_is_valid = 1'b1;
                default:        read_addr_is_valid = 1'b0;
            endcase
        end
    end
    assign read_access_error = ar_handshake && !read_addr_is_valid;

    // Determine write errors before the register commit edge. Bit 0 represents
    // an invalid/unaligned/RO access; bit 1 is start-while-busy; bit 2 is a
    // simultaneous START + SOFT_RESET command.
    reg [2:0] write_error_mask_comb;
    always @* begin
        write_error_mask_comb = 3'b000;
        if (write_commit) begin
            if (awaddr_hold[1:0] != 2'b00) begin
                write_error_mask_comb[ERR_BAD_ACCESS] = 1'b1;
            end else begin
                case (awaddr_hold)
                    ADDR_CTRL: begin
                        if (wstrb_hold[0] && wdata_hold[0] && wdata_hold[1]) begin
                            write_error_mask_comb[ERR_CTRL_CONFLICT] = 1'b1;
                        end else if (wstrb_hold[0] && wdata_hold[0] && busy) begin
                            write_error_mask_comb[ERR_START_WHILE_BUSY] = 1'b1;
                        end
                    end
                    ADDR_ROOT_PTR,
                    ADDR_STATUS,
                    ADDR_ERROR_STATUS,
                    ADDR_IRQ_STATUS,
                    ADDR_IRQ_ENABLE: begin
                        // Supported write targets.
                    end
                    default: begin
                        // ZERO_SKIPS, LATENCY, and unmapped registers are RO/invalid.
                        write_error_mask_comb[ERR_BAD_ACCESS] = 1'b1;
                    end
                endcase
            end
        end
    end
    assign write_error_mask = write_error_mask_comb;
    assign error_set_mask = write_error_mask |
                            (read_access_error ? 3'b001 : 3'b000);

    assign error_clear_mask = (write_commit &&
                               (awaddr_hold == ADDR_ERROR_STATUS) &&
                               (wstrb_hold[0])) ? wdata_hold[2:0] : 3'b000;

    assign irq_clear_mask = (write_commit &&
                             (awaddr_hold == ADDR_IRQ_STATUS) &&
                             (wstrb_hold[0])) ? wdata_hold[2:0] : 3'b000;

    assign clear_completion_sticky = write_commit &&
                                     (awaddr_hold == ADDR_STATUS) &&
                                     wstrb_hold[0] && wdata_hold[1];
    assign clear_early_exit_sticky = write_commit &&
                                     (awaddr_hold == ADDR_STATUS) &&
                                     wstrb_hold[0] && wdata_hold[2];

    assign irq_set_mask = {(|error_set_mask), early_exit_event, completion_event};
    assign irq = |(irq_status & irq_enable);

    // -------------------------------------------------------------------------
    // Write address/data capture, register writes, and B-channel response.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awaddr_hold         <= {ADDR_WIDTH{1'b0}};
            wdata_hold          <= {DATA_WIDTH{1'b0}};
            wstrb_hold          <= {STRB_WIDTH{1'b0}};
            aw_pending          <= 1'b0;
            w_pending           <= 1'b0;
            s_axi_bvalid        <= 1'b0;
            s_axi_bresp         <= AXI_RESP_OKAY;
            start_inference     <= 1'b0;
            soft_reset          <= 1'b0;
            root_descriptor_ptr <= 32'h0000_0000;
            irq_enable          <= 3'b000;
        end else begin
            // Command outputs are one-cycle pulses.
            start_inference <= 1'b0;
            soft_reset      <= 1'b0;

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (aw_handshake) begin
                awaddr_hold <= s_axi_awaddr;
                aw_pending  <= 1'b1;
            end

            if (w_handshake) begin
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
                w_pending  <= 1'b1;
            end

            if (write_commit) begin
                s_axi_bvalid <= 1'b1;
                aw_pending   <= 1'b0;
                w_pending    <= 1'b0;

                if (awaddr_hold[1:0] != 2'b00) begin
                    s_axi_bresp <= AXI_RESP_SLVERR;
                end else begin
                    case (awaddr_hold)
                        ADDR_CTRL: begin
                            if (wstrb_hold[0] && wdata_hold[0] && wdata_hold[1]) begin
                                // Reset wins; start is suppressed. Return SLVERR
                                // so software knows the command combination conflicted.
                                soft_reset  <= 1'b1;
                                s_axi_bresp <= AXI_RESP_SLVERR;
                            end else if (wstrb_hold[0] && wdata_hold[1]) begin
                                soft_reset  <= 1'b1;
                                s_axi_bresp <= AXI_RESP_OKAY;
                            end else if (wstrb_hold[0] && wdata_hold[0]) begin
                                if (busy) begin
                                    // START is rejected while inference is busy.
                                    s_axi_bresp <= AXI_RESP_SLVERR;
                                end else begin
                                    start_inference <= 1'b1;
                                    s_axi_bresp     <= AXI_RESP_OKAY;
                                end
                            end else begin
                                s_axi_bresp <= AXI_RESP_OKAY;
                            end
                        end

                        ADDR_STATUS: begin
                            // W1C is implemented for STATUS bits 1 and 2 only.
                            s_axi_bresp <= AXI_RESP_OKAY;
                        end

                        ADDR_ROOT_PTR: begin
                            s_axi_bresp <= AXI_RESP_OKAY;
                            if (wstrb_hold[0]) root_descriptor_ptr[7:0]   <= wdata_hold[7:0];
                            if (wstrb_hold[1]) root_descriptor_ptr[15:8]  <= wdata_hold[15:8];
                            if (wstrb_hold[2]) root_descriptor_ptr[23:16] <= wdata_hold[23:16];
                            if (wstrb_hold[3]) root_descriptor_ptr[31:24] <= wdata_hold[31:24];
                        end

                        ADDR_ERROR_STATUS,
                        ADDR_IRQ_STATUS: begin
                            // Write-one-to-clear masks are applied in the sticky
                            // status process below.
                            s_axi_bresp <= AXI_RESP_OKAY;
                        end

                        ADDR_IRQ_ENABLE: begin
                            s_axi_bresp <= AXI_RESP_OKAY;
                            if (wstrb_hold[0]) irq_enable <= wdata_hold[2:0];
                        end

                        // Read-only registers and unmapped addresses.
                        default: begin
                            s_axi_bresp <= AXI_RESP_SLVERR;
                        end
                    endcase
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Read address, read-data mux, and R-channel response.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= {DATA_WIDTH{1'b0}};
            s_axi_rresp  <= AXI_RESP_OKAY;
        end else begin
            if (ar_handshake) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rresp  <= AXI_RESP_OKAY;

                if (s_axi_araddr[1:0] != 2'b00) begin
                    s_axi_rdata <= 32'h0000_0000;
                    s_axi_rresp <= AXI_RESP_SLVERR;
                end else begin
                    case (s_axi_araddr)
                        ADDR_CTRL: begin
                            s_axi_rdata <= {30'b0, soft_reset, start_inference};
                        end
                        ADDR_STATUS: begin
                            s_axi_rdata <= {
                                27'b0,
                                irq,
                                (|error_status),
                                early_exit_sticky,
                                completion_sticky,
                                busy
                            };
                        end
                        ADDR_ROOT_PTR: begin
                            s_axi_rdata <= root_descriptor_ptr;
                        end
                        ADDR_ZERO_SKIPS: begin
                            s_axi_rdata <= {12'b0, total_zero_skips};
                        end
                        ADDR_LATENCY: begin
                            s_axi_rdata <= total_latency_cycles;
                        end
                        ADDR_ERROR_STATUS: begin
                            s_axi_rdata <= {29'b0, error_status};
                        end
                        ADDR_IRQ_STATUS: begin
                            s_axi_rdata <= {29'b0, irq_status};
                        end
                        ADDR_IRQ_ENABLE: begin
                            s_axi_rdata <= {29'b0, irq_enable};
                        end
                        default: begin
                            s_axi_rdata <= 32'h0000_0000;
                            s_axi_rresp <= AXI_RESP_SLVERR;
                        end
                    endcase
                end
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Sticky software-polling and interrupt status.
    // Inputs are edge-detected to avoid repeatedly re-raising an event when an
    // upstream status output is level-held high. A new event wins over W1C.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            inference_complete_d <= 1'b0;
            early_exit_d         <= 1'b0;
            completion_sticky    <= 1'b0;
            early_exit_sticky    <= 1'b0;
            error_status         <= 3'b000;
            irq_status           <= 3'b000;
        end else begin
            inference_complete_d <= inference_complete;
            early_exit_d         <= early_exit_occurred;

            completion_sticky <= (completion_sticky & ~clear_completion_sticky) |
                                 completion_event;
            early_exit_sticky <= (early_exit_sticky & ~clear_early_exit_sticky) |
                                 early_exit_event;

            error_status <= (error_status & ~error_clear_mask) | error_set_mask;
            irq_status   <= (irq_status & ~irq_clear_mask) | irq_set_mask;
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_WIDTH != 32) begin
            $error("axi4_lite_slave supports DATA_WIDTH=32 only");
            $finish;
        end
        if (ADDR_WIDTH < 5) begin
            $error("axi4_lite_slave requires ADDR_WIDTH >= 5");
            $finish;
        end
    end
`endif

endmodule
