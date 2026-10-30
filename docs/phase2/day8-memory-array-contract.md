# Phase 2 Day 8 — Memory and Systolic Dataflow Contract

**Package scope:** corrected v2 prototypes for dual-bank scratchpad ownership, a backpressured two-dimensional AGU, and a registered 4x4 systolic SIMD mesh. These files are separate from the legacy module names so that the current `control_unit_top` and existing testbenches are not silently broken.

## 1. Ping-pong SRAM v2

- `active_bank` is read only by the compute side.
- DMA writes only the inactive bank.
- `dma_write_valid && dma_write_ready` accepts one write beat.
- `dma_commit && dma_commit_ready` declares the inactive bank complete and locks further writes.
- `bank_swap_req` is accepted only after commit. `bank_swap_ack` pulses for one cycle and the newly filled bank becomes active.
- An uncommitted swap is rejected with a one-cycle `bank_swap_rejected` pulse.
- Compute reads are synchronous with one-cycle `compute_read_valid`.
- A read is suppressed on the ownership-swap edge. The system sequencer must swap only at a safe tile/layer boundary and must drain outstanding reads first.
- SRAM contents are not reset; valid data must be written before it is read.

The producer must not assert `dma_commit` until all beats for the next bank have been accepted. The DMA write address is a word index into the selected inactive bank, not a byte address.

## 2. AGU v2

- `start_valid && start_ready` latches one 2-D geometry request.
- `addr_valid && addr_ready` consumes an address. If `addr_ready=0`, both `addr_valid` and `addr` remain stable.
- The row address is `base_addr + row*row_stride_bytes + col*WORD_BYTES`.
- `WORD_BYTES` defaults to 8 for the 64-bit scratchpad/DMA word.
- Zero dimensions, unaligned base address, undersized/non-word-aligned row stride, and address overflow are rejected with error codes 1–4.
- `done` is a one-cycle pulse after the final address handshake; it does not mean matrix computation or output writeback is complete.

The current Phase 3 DMA reader must consume each address through this ready/valid interface. Do not connect `addr_valid` to a one-cycle DMA launch without a ready/acceptance handshake.

## 3. Systolic array v2

- The mesh has 4 rows x 4 columns (16 PEs).
- Activations travel east; weights travel south. Every PE boundary crossing is registered.
- The tile feeder must skew activation row `r` by `r` cycles and weight column `c` by `c` cycles. This aligns activation and weight token `k` at PE[r][c].
- `act_row_valid/last` and `weight_col_valid/last` travel with their corresponding data.
- `advance` stalls every forwarding register and accumulator together. The feeder must hold boundary inputs stable while `advance=0`.
- `acc_clear` clears all PE accumulators, valid pipeline stages, tile completion tracking and sticky error flags before a new output tile.
- INT8 mode accumulates two independent signed byte lanes. INT4 mode accumulates four independent signed nibble lanes.
- Each lane has a signed 32-bit accumulator; the four lanes form a 128-bit accumulator per PE. Overflow saturates the affected lane to signed 32-bit limits and sets `accum_overflow`.
- FP16 is unsupported in this Phase 2 integer mesh.
- `pe_result_valid[r*4+c]` pulses when PE[r][c] has accepted the last aligned product for the tile. `tile_done` pulses once all 16 PEs have reported their result-valid event and remains asserted until `acc_clear` establishes the next tile boundary.
- `config_error` flags unsupported precision when valid operands are presented. `protocol_error` flags a valid mismatch between activation and weight at a PE.

The array exposes **raw accumulators**, not requantized tensor outputs. A downstream post-processing block must consume each 32-bit lane, apply the appropriate scale/shift/zero-point and saturation policy, then pack the result for output DMA. The legacy `pe_top` narrows its result to 16 bits and therefore is not used by this v2 array; the old array/PE contract must not be mixed with the v2 128-bit lane contract.

## 4. Golden-model test coverage

- Ping-pong test: writes inactive bank, commits, rejects further writes before swap, swaps, reads back values, writes the other bank while compute reads the active bank, performs a second swap, and rejects an uncommitted swap.
- AGU test: checks a 2x3 tensor address sequence with 8-byte words and 32-byte row stride, verifies address stability under three cycles of backpressure, and rejects zero dimensions, unaligned base, insufficient stride and address overflow.
- Array test: streams a 4x4x3 INT8 tile with two independent packed byte lanes and checks all 32 results against software-derived matrix products; clears and repeats an INT4 tile with four independent nibble lanes. It checks tile completion and that protocol/configuration/overflow flags remain clear.

## 5. Integration work still required

1. Update the tile feeder to produce the documented row/column skew and valid/last schedule.
2. Update the sequencer to wait for `tile_done`, not AGU `done`; AGU completion only indicates that addresses have been issued/accepted.
3. Connect ping-pong `dma_commit`, prefetch-complete, swap request/acknowledgement and compute read-valid to the sequencer/feeder.
4. Implement the lane-wise post-processing stage for the 128-bit PE accumulators. Do not pass the 128-bit array results through legacy `pe_top` or the old 32-bit `post_processor` interface unchanged.
5. Add a full top-level layer test before claiming end-to-end Phase 2 completion. AXI4 read/write DMA remains Phase 3 work.

## 6. Verification status

These files are a Day 8 implementation package. Run `scripts/run_day8_memory_array.sh` with Icarus Verilog (`iverilog -g2012`). Do not commit or call Day 8 complete until all three self-checking testbenches pass locally. A simulator was not available in the authoring environment, so no local simulation pass is claimed here.
