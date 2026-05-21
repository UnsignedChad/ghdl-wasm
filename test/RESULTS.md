# GHDL-WASM Test Circuit Results

## Summary

All 7 new circuits analyzed, elaborated, and converted to WASM successfully after patching two bugs in the GHDL WASM backend (src/ortho/wasm/ortho_wasm.adb).

## Results Table

| Circuit | Analyze | Elab/WAT | wat2wasm | WASM Size | Notes |
|---------|---------|----------|----------|-----------|-------|
| half_adder | pass | pass | pass | ~10KB | baseline (prior run) |
| full_adder | pass | pass | pass | 11559 B | all 8 input combos tested |
| ripple4 | pass | pass | pass | 83962 B | structural, 4x full_adder; uses generate loop |
| dff | pass | pass | pass | 10917 B | sync reset, clocked process |
| counter4 | pass | pass | pass | 82517 B | sync reset+enable; numeric_std |
| mux4to1 | pass | pass | pass | 11605 B | case statement over sel vector |
| shift_reg | pass | pass | pass | 11496 B | 8-bit SIPO, shift pattern |
| alu | pass | pass | pass | 85911 B | ADD/SUB/AND/OR; numeric_std |

## Bugs Fixed in ghdl_wasm (ortho_wasm.adb)

### Bug 1: Missing WAT import declarations

Symptom: wat2wasm errors: undefined function variable for 5 runtime functions.

Root cause: The hardcoded import list in the Init procedure was missing 5 runtime
function imports needed by any design using std_logic_vector or IEEE library internals.

Fix: Added the 5 missing imports to the Init procedure:
- __ghdl_stack2_mark (result i32)
- __ghdl_stack2_release (param i32)
- __ghdl_check_stack_allocation (param i32)
- __ghdl_ieee_assert_failed (param i32 i32 i32 i32)
- __ghdl_i32_mod (param i32 i32) (result i32)

Impact: This bug made ALL circuits using std_logic_vector or numeric_std fail at wat2wasm.

### Bug 2: Type mismatch in loop variable initialization

Symptom: wat2wasm errors: type mismatch in local.set, expected i32 but got i64 -- 37 occurrences.

Root cause: New_Convert_Ov was a no-op (pragma Unreferenced; return Val), so when a
for-loop range bound typed as i64 was assigned to an i32 loop iterator, the type
conversion was silently dropped.

Fix: Implemented New_Convert_Ov to detect i64->i32 conversions and emit Ek_Wrap_I32
nodes, plus added Ek_Wrap_I32 expression kind that emits (i32.wrap_i64 ...) in WAT.

Impact: Affects any design with for-loops (generate statements, for...loop constructs),
i.e. ripple4, counter4, alu.

## Size Patterns

- Simple combinatorial (full_adder, dff, mux4to1, shift_reg): ~10-12 KB
- Circuits using std_logic_vector ops with for-loops (ripple4, counter4, alu): ~82-86 KB
  Larger due to full IEEE numeric_std elaboration being included.
