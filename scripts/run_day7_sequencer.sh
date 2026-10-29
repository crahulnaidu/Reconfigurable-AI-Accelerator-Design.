#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-day7"

IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

if ! mkdir -p "$BUILD_DIR"; then
    echo "FAIL: Cannot create build directory"
    exit 2
fi

OUT="$BUILD_DIR/tb_sequencer_fsm_v2.vvp"
LOG="$BUILD_DIR/simulation.log"
COMPILE_LOG="$BUILD_DIR/compile.log"

echo "========================================"
echo "DAY 7: SEQUENCER FSM VERIFICATION"
echo "========================================"

# Compile the new sequencer and self-checking testbench.
if ! "$IVERILOG" -g2012 -Wall \
    -s tb_sequencer_fsm_v2 \
    -o "$OUT" \
    "$ROOT_DIR/rtl/control/sequencer_fsm_v2.v" \
    "$ROOT_DIR/tb/control/tb_sequencer_fsm_v2.v" \
    >"$COMPILE_LOG" 2>&1; then

    cat "$COMPILE_LOG"
    echo "FAIL: Day 7 sequencer compilation failed"
    exit 1
fi

cat "$COMPILE_LOG"

# Run the simulation.
if ! "$VVP" "$OUT" >"$LOG" 2>&1; then
    cat "$LOG"
    echo "FAIL: Day 7 sequencer simulation exited with an error"
    exit 1
fi

cat "$LOG"

# Detect explicit failure markers at the start of a line.
# Do not search for the word "error" anywhere: successful
# test descriptions can legitimately contain that word.
if grep -Eiq \
    '^[[:space:]]*(FAIL:|FATAL:|ERROR:|FAILURE:)' "$LOG"; then
    echo "FAIL: Explicit failure marker detected in simulation log"
    exit 1
fi

# Require the testbench's own final success marker.
if ! grep -Fq \
    "SEQUENCER FSM VERIFICATION PASSED" "$LOG"; then
    echo "FAIL: Sequencer success marker not found"
    exit 1
fi

echo "PASS: Day 7 sequencer FSM verification"
exit 0
