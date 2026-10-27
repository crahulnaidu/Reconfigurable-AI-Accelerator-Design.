#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-regression"

IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

if ! mkdir -p "$BUILD_DIR"; then
    echo "ERROR: Cannot create build directory: $BUILD_DIR"
    exit 2
fi

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
    local name="$1"
    local top="$2"
    local success_marker="$3"
    shift 3

    local output="$BUILD_DIR/${name}.vvp"
    local compile_log="$BUILD_DIR/${name}.compile.log"
    local sim_log="$BUILD_DIR/${name}.sim.log"

    echo
    echo "========================================"
    echo "TEST: $name"
    echo "========================================"

    # Compile the testbench and its required RTL.
    if ! "$IVERILOG" -g2012 -Wall \
        -s "$top" \
        -o "$output" \
        "$@" >"$compile_log" 2>&1; then

        cat "$compile_log"
        echo "FAIL: $name (compilation failed)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    # Show warnings even when compilation succeeds.
    cat "$compile_log"

    # Capture simulation output so it can be checked.
    if ! "$VVP" "$output" >"$sim_log" 2>&1; then
        cat "$sim_log"
        echo "FAIL: $name (simulation exited with an error)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    cat "$sim_log"

    # Detect explicit failures, fatal errors, or error messages.
    # "Failures: 0" is intentionally not treated as a failure.
    if grep -Eiq \
        '(^|[^[:alnum:]_])(fail([[:space:]:]|ed([^[:alnum:]_]|$)|$)|fatal([^[:alnum:]_]|$)|error[[:space:]:])' \
        "$sim_log"; then

        echo "FAIL: $name (failure/error text detected in simulation output)"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    # Require a testbench-specific success marker.
    if ! grep -Fq "$success_marker" "$sim_log"; then
        echo "FAIL: $name (expected success marker not found)"
        echo "Expected marker: $success_marker"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
}

# Test 1: Signed 8-bit multiplier.
run_test \
    "mult8_signed" \
    "tb_mult8_signed" \
    "PASS: All multiplier comparisons matched." \
    "$ROOT_DIR/rtl/pe/mult8_signed.v" \
    "$ROOT_DIR/tb/pe/tb_mult8_signed.sv"

# Test 2: PE multiplier: INT8, INT4, and FP16 directed tests.
run_test \
    "pe_multiplier" \
    "tb_pe_multiplier" \
    "MULTIPLIER VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/pe/pe_multiplier.v" \
    "$ROOT_DIR/tb/pe/tb_pe_multiplier.v"

# Test 3: Processing element.
run_test \
    "processing_element" \
    "tb_processing_element" \
    "DAY 2 PE TESTS PASSED" \
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
echo "Logs:   $BUILD_DIR"

if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi

echo "ALL REGRESSION TESTS PASSED"
exit 0
