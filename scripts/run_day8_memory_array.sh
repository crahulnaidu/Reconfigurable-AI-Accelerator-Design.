#!/usr/bin/env bash
set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-day8"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
mkdir -p "$BUILD_DIR" || exit 2
PASS_COUNT=0
FAIL_COUNT=0

run_one() {
    local name="$1" top="$2" marker="$3"
    shift 3
    local image="$BUILD_DIR/${name}.vvp"
    local compile_log="$BUILD_DIR/${name}.compile.log"
    local sim_log="$BUILD_DIR/${name}.sim.log"

    echo
    echo "========================================"
    echo "DAY 8 TEST: $name"
    echo "========================================"

    if ! "$IVERILOG" -g2012 -Wall -s "$top" -o "$image" "$@" >"$compile_log" 2>&1; then
        cat "$compile_log"
        echo "FAIL: $name compilation"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    cat "$compile_log"

    if ! "$VVP" "$image" >"$sim_log" 2>&1; then
        cat "$sim_log"
        echo "FAIL: $name simulation exit"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    cat "$sim_log"

    if grep -Eiq '^[[:space:]]*(FAIL:|FATAL:|ERROR:|FAILURE:)' "$sim_log"; then
        echo "FAIL: $name explicit failure marker"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    if ! grep -Fq "$marker" "$sim_log"; then
        echo "FAIL: $name success marker missing"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
}

run_one "ping_pong_sram_v2" "tb_ping_pong_sram_v2" \
    "PING-PONG SRAM VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/memory/ping_pong_sram_v2.v" \
    "$ROOT_DIR/tb/memory/tb_ping_pong_sram_v2.v"

run_one "agu_v2" "tb_agu_v2" \
    "AGU VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/memory/agu_v2.v" \
    "$ROOT_DIR/tb/memory/tb_agu_v2.v"

run_one "systolic_array_v2" "tb_systolic_array_v2" \
    "SYSTOLIC ARRAY VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/array/systolic_array_v2.v" \
    "$ROOT_DIR/tb/array/tb_systolic_array_v2.v"

echo
echo "========================================"
echo "DAY 8 SUMMARY"
echo "========================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "Logs:   $BUILD_DIR"
if [ "$FAIL_COUNT" -ne 0 ]; then exit 1; fi
echo "ALL DAY 8 TESTS PASSED"
exit 0
