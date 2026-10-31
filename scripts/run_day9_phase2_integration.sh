#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${TMPDIR:-/tmp}/reconfigurable-ai-accelerator-day9"
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"

if ! mkdir -p "$BUILD_DIR"; then
    echo "FAIL: cannot create Day 9 build directory"
    exit 2
fi

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
    echo "DAY 9 TEST: $name"
    echo "========================================"

    if ! "$IVERILOG" -g2012 -Wall -s "$top" -o "$image" "$@" >"$compile_log" 2>&1; then
        cat "$compile_log"
        echo "FAIL: $name compilation failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    cat "$compile_log"

    if ! "$VVP" "$image" >"$sim_log" 2>&1; then
        cat "$sim_log"
        echo "FAIL: $name simulation exited unsuccessfully"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    cat "$sim_log"

    if grep -Eiq '^[[:space:]]*(FAIL:|FATAL:|ERROR:|FAILURE:)' "$sim_log"; then
        echo "FAIL: $name explicit failure marker detected"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi
    if ! grep -Fq "$marker" "$sim_log"; then
        echo "FAIL: $name required success marker missing"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 0
    fi

    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
}

COMMON_RTL=(
    "$ROOT_DIR/rtl/control/descriptor_engine.v"
    "$ROOT_DIR/rtl/control/sequencer_fsm_v2.v"
    "$ROOT_DIR/rtl/memory/agu_v2.v"
    "$ROOT_DIR/rtl/memory/ping_pong_sram_v2.v"
    "$ROOT_DIR/rtl/pe/systolic_tile_feeder_v2.v"
    "$ROOT_DIR/rtl/array/systolic_array_v2.v"
    "$ROOT_DIR/rtl/pe/post_processor_mesh_v2.v"
)

run_one "sequencer_fsm_v2" "tb_sequencer_fsm_v2" \
    "SEQUENCER FSM VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/control/sequencer_fsm_v2.v" \
    "$ROOT_DIR/tb/control/tb_sequencer_fsm_v2.v"

run_one "systolic_array_v2" "tb_systolic_array_v2" \
    "SYSTOLIC ARRAY VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/array/systolic_array_v2.v" \
    "$ROOT_DIR/tb/array/tb_systolic_array_v2.v"

run_one "phase2_accelerator_core_v2" "tb_phase2_accelerator_core_v2" \
    "PHASE 2 INTEGRATION VERIFICATION PASSED" \
    "${COMMON_RTL[@]}" \
    "$ROOT_DIR/rtl/phase2_accelerator_core_v2.v" \
    "$ROOT_DIR/tb/tb_phase2_accelerator_core_v2.sv"

run_one "post_processor_mesh_v2" "tb_post_processor_mesh_v2" \
    "POST-PROCESSOR MESH VERIFICATION PASSED" \
    "$ROOT_DIR/rtl/pe/post_processor_mesh_v2.v" \
    "$ROOT_DIR/tb/tb_post_processor_mesh_v2.sv"

echo
echo "========================================"
echo "DAY 9 SUMMARY"
echo "========================================"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "Logs:   $BUILD_DIR"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
echo "ALL DAY 9 TESTS PASSED"
exit 0
