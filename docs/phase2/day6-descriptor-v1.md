# Day 6 — Version-1 Layer Descriptor Engine

## Purpose
Replace the earlier six-field/three-bit-index parser with a self-checking parser for the architecture requirements' version-1, 32-word (128-byte) descriptor.

## Streaming contract used for this Phase 2 step
- `load_descriptor_en` means one 32-bit word is being presented on this clock edge.
- `word_index` must arrive in order from 0 through 31.
- Word 0 starts a new frame. A missing/out-of-order word aborts the frame.
- `descriptor_done` is a one-cycle pulse when a full frame is received or a word-order failure aborts the frame.
- `descriptor_valid` is asserted only after all fields have been validated and atomically committed.
- `config_error` and `error_code` remain sticky until reset or a new word-0 frame begins.
- This is a parser, not the AXI descriptor DMA. The later Phase 3 DMA must feed accepted 32-bit words in order from the 64-bit memory stream.

## Word layout
| Word(s) | Field | Meaning |
|---|---|---|
| 0–1 | A_BASE[63:0] | Activation base, low word first |
| 2–3 | B_BASE[63:0] | Weight base |
| 4–5 | C_BASE[63:0] | Output base |
| 6–7 | NEXT_DESC[63:0] | Next layer descriptor; zero terminates sequential traversal |
| 8–9 | EXIT_DESC[63:0] | Optional alternate/early-exit descriptor |
| 10–11 | BIAS_BASE[63:0] | Optional bias array |
| 12 | CFG | [1:0] precision: 01 INT8, 10 INT4; bit 2 zero-bypass; bit 3 exit head; bit 4 ReLU; bit 5 bias enable; [31:6] reserved zero |
| 13 | SCALE_Q31 | Signed fixed-point multiplier bits |
| 14 | QCFG | [7:0] output zero point; [12:8] right shift; [31:13] reserved zero |
| 15 | M_N | M in [15:0], N in [31:16] |
| 16 | K | K in [15:0], [31:16] reserved zero |
| 17 | A_TILE_STRIDE_BYTES | M-block stride in packed activation layout |
| 18 | B_TILE_STRIDE_BYTES | N-block stride in packed weight layout |
| 19 | C_TILE_STRIDE_BYTES | Output-tile stride |
| 20 | CONF_MARGIN_THRESHOLD | Unsigned confidence-margin threshold; high 16 bits must be zero in v1 |
| 21 | DEADLINE_CYCLES | 0 disables deadline enforcement |
| 22 | LAYER_ID | Software-visible ID |
| 23 | DESC_VERSION_LENGTH | low 16 bits = version 1; high 16 bits = 32 words |
| 24–31 | RESERVED | Must be zero |

All pointers are 64-bit in the descriptor; default `ADDR_WIDTH=32` rejects nonzero upper words. Set `ADDR_WIDTH=64` only when the connected memory master truly supports 64-bit addresses.

## Validation rules in this step
- Correct word order, version and length.
- Only INT8 (01) and INT4 (10) are accepted; FP16 is rejected for the end-to-end version-1 path.
- M/N/K must be nonzero.
- A/B/C bases must be nonzero and 8-byte aligned; descriptor links must be 128-byte aligned when nonzero; enabled bias must be nonzero and 4-byte aligned.
- For a 32-bit target, pointer high words must be zero.
- A/B tile strides must be 8-byte aligned and at least `ceil(K/2)*8` for INT8 or `ceil(K/4)*8` for INT4. C tile stride must be 8-byte aligned and at least 16 bytes for INT8 or 8 bytes for INT4.
- Reserved bits/words must be zero.
- Invalid descriptors do not overwrite the last committed configuration. Consumers must gate execution on `descriptor_valid`.

## Error codes
`00` none; `01` word order; `02` version/length; `03` unsupported precision; `04` dimensions; `05` alignment; `06` stride; `07` address/width; `08` reserved bits/words.

## Run
From repository root:
```bash
./scripts/run_day6_descriptor.sh
```
The testbench has assertions; it calls `$fatal` if a check fails and prints `DESCRIPTOR ENGINE VERIFICATION PASSED` only after all checks pass.

## Integration warning
This step upgrades only the descriptor parser and its direct testbench. `sequencer_fsm.v`, `control_unit_top.v`, the AGU, and the descriptor DMA adapter must be updated in the next steps to use the 32-word index and the parser's `descriptor_done`, `descriptor_valid`, and `config_error` contract. Do not claim end-to-end Phase 2 integration from this unit test alone.
