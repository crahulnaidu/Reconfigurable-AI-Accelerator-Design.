# Phase 2 Day 8 Package

New v2 prototypes (legacy RTL files are not overwritten):

- `rtl/memory/ping_pong_sram_v2.v`
- `rtl/memory/agu_v2.v`
- `rtl/array/systolic_array_v2.v`
- Self-checking testbenches under `tb/`
- `scripts/run_day8_memory_array.sh`
- `docs/phase2/day8-memory-array-contract.md`

From the repository root, unzip this package, then run:

```bash
chmod +x scripts/run_day8_memory_array.sh
./scripts/run_day8_memory_array.sh
```

This package has not been executed in the author's environment because Icarus Verilog was unavailable. Local passing simulations are required before commit.
