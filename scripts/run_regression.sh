#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-regression"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

mkdir -p "$BUILD_DIR"

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
    local name="$1"
    local top="$2"
    shift 2
    local output="$BUILD_DIR/${name}.vvp"

    echo
    echo "========================================"
    echo "TEST: $name"
    echo "========================================"

    if ! "$IVERILOG" -g2012 -Wall \
        -s "$top" \
        -o "$output" \
        "$@"; then
        echo "FAIL: $name (compilation failed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return
    fi

    if "$VVP" "$output"; then
        echo "PASS: $name (simulation exited successfully)"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "FAIL: $name (simulation failed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

run_test \
    "mult8_signed" \
    "tb_mult8_signed" \
    "$ROOT_DIR/rtl/pe/mult8_signed.v" \
    "$ROOT_DIR/tb/pe/tb_mult8_signed.sv"

run_test \
    "processing_element" \
    "tb_processing_element" \
    "$ROOT_DIR/rtl/pe/mult8_signed.v" \
    "$ROOT_DIR/rtl/pe/pe_multiplier.v" \
    "$ROOT_DIR/rtl/pe/processing_element.v" \
    "$ROOT_DIR/tb/pe/tb_processing_element.v"

echo
echo "========================================"
echo "REGRESSION SUMMARY"
echo "========================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi

exit 0
