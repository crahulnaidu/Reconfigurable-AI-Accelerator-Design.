# Phase 2 Day 7 — Sequencer FSM v2 contract

## Purpose

This FSM orchestrates descriptor loading, per-layer computation, confidence evaluation when the current descriptor marks an exit head, output writeback, and graph traversal. It deliberately uses the name `sequencer_fsm_v2` so the existing `control_unit_top.v` is not silently broken before its planned integration update.

## Required handshakes

- `descriptor_fetch_start`: one-cycle request to fetch `active_descriptor_ptr`.
- `descriptor_done`: one-cycle pulse from the descriptor parser after a full descriptor frame has been assembled and validated/rejected.
- `descriptor_valid` / `config_error` / `descriptor_error_code`: stable descriptor result associated with `descriptor_done`.
- `layer_start`: one-cycle pulse to launch the complete layer/tile pipeline.
- `compute_done`: asserts only after all output tiles and post-processing for this layer are complete. AGU completion alone is not sufficient.
- `confidence_eval_start`: pulse on launch of a descriptor whose `cfg_flags[4]` marks an exit head and global early exit is enabled.
- `confidence_done`: must be held high with a stable `early_exit_trigger` until consumed by the FSM; future integration should make this a proper valid/ready or sticky-clear handshake.
- `output_write_start`: one-cycle pulse to launch output DMA/writeback.
- `writeback_done`: indicates all required output writes completed with successful AXI responses.
- `engine_error`: aborts active work and propagates `engine_error_code` (or internal ERR_ENGINE if zero).

## State sequence

`IDLE -> FETCH_REQ -> WAIT_DESC -> START_LAYER -> WAIT_COMP -> [WAIT_CONF] -> START_WR -> WAIT_WR -> ROUTE -> (FETCH_REQ or DONE)`.

Any descriptor rejection routes to `ERROR` before `layer_start`. `engine_error` during active work also routes to `ERROR`. A new `start_inference` is accepted in IDLE, DONE or ERROR.

## Descriptor flags and pointer rules

- `cfg_flags[4]` means EXIT_HEAD for descriptor version 1.
- `next_descriptor_ptr != 0` selects the next sequential descriptor after successful writeback.
- If confidence completes and early exit is enabled and triggered, a nonzero `exit_descriptor_ptr` is selected after writeback. If the exit pointer is zero, inference completes at that exit head.
- A zero next pointer without an accepted early exit means inference completes normally.

## Deliberate design decisions

- Descriptor fields are latched when a valid descriptor is accepted; subsequent parser changes must not affect the current layer's route.
- The FSM only sequences; it does not itself fetch DRAM. `descriptor_fetch_start` launches the later DMA/streaming integration.
- Output writeback must finish before `NEXT_DESC`/`EXIT_DESC` routing or terminal `DONE`.
- Timeout/deadline counting belongs in a cycle-monitor/engine-error path and will be integrated with telemetry.
- Current `control_unit_top.v` still uses the legacy sequencer interface. Do not replace the legacy module name or claim top-level integration until that top and its testbench are updated together.
