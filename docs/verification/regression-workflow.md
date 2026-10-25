# RTL Regression Workflow

## Requirements
- Icarus Verilog
- VVP runtime
- Bash-compatible shell

## Run the regression
From the repository root:

```bash
./scripts/run_regression.sh
## Current test coverage
- Signed 8-bit multiplier testbench
- Processing-element testbench

## Result interpretation
- PASS: compilation and simulation exited successfully.
- FAIL: compilation or simulation returned a nonzero status.
- Compiler warnings are displayed and should be reviewed.

## Limitations
A successful simulator exit does not by itself prove that every
assertion passed. Testbench-specific failure reporting must also
be checked. The regression currently covers only the two listed
testbenches; it is not a full accelerator regression.
