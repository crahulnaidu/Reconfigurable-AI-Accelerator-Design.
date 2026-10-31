# Phase 2 Day 9 — Integrated single-tile core contract

## 1. Scope and design boundary

`phase2_accelerator_core_v2` integrates:

- Version-1 32-word descriptor parser and sequencer FSM v2.
- Separate activation and weight AGU v2 instances.
- Separate activation and weight ping-pong SRAM v2 instances.
- One-cycle paired SRAM response buffering.
- A 64-bit word unpacker and registered row/column skew feeder.
- Registered 4x4 systolic mesh.
- Lane reduction, requantization, signed output formatting and saturation telemetry.
- A one-tile scheduler that requests K-group words after both AGUs finish and both scratchpad bank swaps are acknowledged.

The demonstrator is deliberately limited to one 4x4 output tile (`M=4`, `N=4`) and a K length that fits the local scratchpad. It rejects dimensions other than 4x4 rather than silently truncating them. Multi-tile traversal remains a separate scheduler extension.

The descriptor source, activation/weight DMA request/response data path, bank commit/swap requests and output writer are external handshakes in this Phase 2 shell. The testbench models these external memory/DMA functions deterministically. Actual AXI4 master engines and interconnect remain Phase 3 work.

## 2. Descriptor and packed K layout

The 32-word descriptor provides A/B/C base addresses, next/exit pointers, precision, scale, shift, zero point, M/N/K, A/B/C tile strides, confidence threshold, deadline, layer ID, version and reserved fields.

For this integrated 64-bit feeder:

- INT8 uses two signed byte lanes. Each 16-bit row/column vector holds two consecutive K values. `K_groups = ceil(K/2)`.
- INT4 uses four signed nibble lanes. Each 16-bit row/column vector holds four consecutive K values. `K_groups = ceil(K/4)`.
- One activation 64-bit word carries four 16-bit row vectors (one per systolic row).
- One weight 64-bit word carries four 16-bit column vectors (one per systolic column).
- Weight words are stored output-column-major (pre-transposed).
- One 64-bit packed word represents one K group; therefore each A/B packed tile needs `K_groups * 8` bytes.

Descriptor CFG follows the Day 6 word map: bit 2 enables per-SIMD-lane zero bypass, bit 3 marks an EXIT_HEAD, bit 4 is ReLU, and bit 5 enables bias. The Day 9 sequencer uses CFG bit 3 for EXIT_HEAD; this corrects the earlier Day 7 v2 bit-4 mismatch.

When zero bypass is enabled, a lane is bypassed if either its activation or weight operand is zero. Bypass is lane-wise (two lanes per INT8 PE, four per INT4 PE), not whole-packed-word bypass. `zero_skip_count` counts valid lane-products skipped over the tile. This is an activity proxy, not a direct energy measurement.

The mesh accumulates each SIMD lane independently. The post-processor must sign-extend the lanes to 34 bits before adding them; otherwise the lane reduction could overflow at 32 bits before reaching the wider accumulator. It then multiplies by scale, applies arithmetic shift and signed zero point, and saturates to INT8/INT4. The result port is signed 16-bit (INT8/INT4 value sign-extended).

This lane-reduction rule is essential: the mesh lanes are partial K accumulators, not separate output elements. The post-processor reduction produces one scalar GEMM result per PE.

## 3. Execution and handshake sequence

1. Controller pulses `start_inference` with the 64-bit root descriptor pointer.
2. Sequencer pulses `descriptor_fetch_start`. The external descriptor source returns 32 ordered 32-bit words using `descriptor_word_valid/index/data` and obeys `descriptor_word_ready`.
3. Descriptor parser validates and atomically commits the frame. The top accepts only `M=N=4` and `K_groups` that fit local SRAM.
4. Sequencer pulses `layer_start`; the pulse launches both AGUs and clears the mesh, feeder and post-processor for the new layer.
5. Each AGU emits one 32-bit byte address per packed K group and holds `addr/VALID` stable until `addr_ready`. AGU `done` means all addresses were accepted by the external memory request interface; it does not mean tensor data arrived or compute completed.
6. External memory/DMA model writes returned A/B words into inactive SRAM banks. After all words arrive, it asserts each `dma_commit`, then issues one-cycle `bank_swap_req` pulses. The top latches the activation and weight swap acknowledgements independently and clears `banks_ready` at each new layer start.
7. The internal one-tile reader starts only when both AGUs are done and both banks are ready. It issues paired activation/weight read requests for `K_groups` local addresses. A response bridge waits for both synchronous SRAM read-valid signals and holds the word pair until the feeder accepts it.
8. The feeder delays activation row `r` by `r` accepted mesh advances and weight column `c` by `c` advances. `valid` and `last` tags travel with each operand. The mesh's `advance` input freezes feeder and mesh registers together; the top holds the current word pair when `advance=0`.
9. The 4x4 mesh forwards activations east and weights south through registered PE boundaries. Every PE accumulates its two INT8 or four INT4 partial-K lanes. The mesh reports `array_tile_done` after all 16 PE last tokens have reached their destinations.
10. The lane-aware post-processor reduces the SIMD lanes, requantizes, sign-extends the scalar result to 16 bits, records saturation events, and holds each result until `postproc_result_ready`.
11. For this one-tile core, `postproc_tile_done` is sequencer `compute_done`. Sequencer pulses `output_write_start` and waits for external `writeback_done` before reporting `inference_complete`.

`DONE` from either AGU is never used as `compute_done`.

## 4. Important interfaces

### Controller/descriptor side

- `start_inference`, `root_descriptor_ptr`, `global_early_exit_enable`
- `descriptor_fetch_start`, `active_descriptor_ptr`
- `descriptor_word_valid`, `descriptor_word_ready`, `descriptor_word_index`, `descriptor_word_data`

### Activation/weight request and data-return side

- `act_addr_valid/ready/addr`, `weight_addr_valid/ready/addr`
- `act_dma_write_valid/ready/addr/data`, `weight_dma_write_valid/ready/addr/data`
- Separate `dma_commit`, `prefetch_complete`, `bank_swap_req`, `bank_swap_ack`, `bank_swap_rejected`, and `banks_ready`

### Internal one-tile read scheduler trace

- `tile_word_read_req/ready/addr/last` are observation ports for verification. The actual two SRAM read enables are generated internally from the request handshake; the supervisory controller does not schedule individual K-group reads.
- `array_advance` is a global mesh advance/backpressure input; tie high for the first non-stalled integration run.

### Output and status side

- `postproc_result_valid[15:0]`, `postproc_result_ready[15:0]`, `postproc_result_data[0:3][0:3]`
- `postproc_tile_done`, `output_write_start`, `writeback_done`, `zero_skip_count`
- `busy`, `inference_complete`, `early_exit_occurred`, `error`, `error_code`
- Descriptor observability includes A/B/C bases, M/N/K/K-groups, precision, requantization settings, confidence threshold, deadline and layer ID.

## 5. Validation coverage

`tb_phase2_accelerator_core_v2.sv` models descriptor memory, external A/B request acceptance, tensor data return to the inactive banks, commit/swap, and output writer behavior. It checks two AGU addresses per tensor, two internally issued K-group reads, an INT8 4x4 signed GEMM against a software-derived golden matrix, signed output extension, saturation count, and completion only after writeback.

`tb_systolic_array_v2.sv` additionally checks that zero bypass preserves the GEMM lane results and counts valid skipped lane-products.

`tb_post_processor_mesh_v2.sv` independently checks INT8 two-lane reduction, negative output sign extension, INT8 saturation counting, INT4 four-lane reduction and INT4 saturation counting.

## 6. Exclusions and honest status

- No AXI4 descriptor/activation/weight/output master implementation is included. Phase 2 external interfaces and testbench models stand in for those DMA engines.
- The core executes one 4x4 output tile. It does not support arbitrary M/N tile traversal.
- Confidence threshold is exposed to an external confidence evaluator. The classifier/logit path is not instantiated here.
- Bias addition and ReLU are not integrated in this post-processor revision.
- FP16 is disabled in the Phase 2 systolic mesh.
- `deadline_cycles` is parsed/exposed, but deadline enforcement is not part of this Day 9 core.
- Power, energy, temperature, battery and DVFS remain platform integration responsibilities.
- The Day 9 HDL package must pass local Icarus Verilog simulation before it is considered verified. This authoring environment did not have Icarus Verilog installed.

## 7. Acceptance

The sequencer, systolic array, integrated `phase2_accelerator_core_v2`, and `post_processor_mesh_v2` testbenches must compile and pass with no explicit failure markers. The integrated test must demonstrate descriptor fetch/parse, two AGU address streams, inactive-bank writes/commit/swap, automatic paired SRAM reads, feeder skew, a signed 4x4 INT8 GEMM, lane-reduction post-processing, output-result backpressure, sequencer writeback wait and inference completion.
