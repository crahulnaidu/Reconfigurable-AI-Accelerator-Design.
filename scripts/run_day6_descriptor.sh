#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-day6"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
mkdir -p "$BUILD_DIR"
OUT="$BUILD_DIR/tb_descriptor_engine.vvp"
LOG="$BUILD_DIR/tb_descriptor_engine.log"

if ! "$IVERILOG" -g2012 -Wall -s tb_descriptor_engine -o "$OUT" \
    "$ROOT_DIR/rtl/control/descriptor_engine.v" \
    "$ROOT_DIR/tb/control/tb_descriptor_engine.v"; then
    echo "FAIL: descriptor_engine compilation failed"
    exit 1
fi

if ! "$VVP" "$OUT" > "$LOG" 2>&1; then
    cat "$LOG"
    echo "FAIL: descriptor_engine simulation failed"
    exit 1
fi
cat "$LOG"
if grep -Eiq '(^|[[:space:]])(FAIL:|FATAL:|ERROR:)' "$LOG"; then
    echo "FAIL: explicit failure/error text detected"
    exit 1
fi
if ! grep -Fq 'DESCRIPTOR ENGINE VERIFICATION PASSED' "$LOG"; then
    echo "FAIL: descriptor testbench success marker missing"
    exit 1
fi
echo "PASS: Day 6 descriptor engine verification"
