# ghdl-wasm

A fork of [GHDL](https://github.com/ghdl/ghdl) that adds a **WebAssembly (WASM) backend**, enabling VHDL designs to be compiled and simulated directly in the browser.

**Try it without building anything:** [vhdl.ai/vhdlive](https://vhdl.ai/vhdlive) hosts a live deployment that exercises both this backend and [ghdl-browser](https://github.com/UnsignedChad/ghdl-browser) — open it in any modern browser, write VHDL, hit Simulate.

> **Looking for the in-browser GHDL itself?** This repo holds the *compiler backend* — the Ada code under
> `src/ortho/wasm/` that teaches GHDL how to emit WebAssembly text (WAT) instead of native machine code.
> If you want the user-facing port of GHDL that actually runs `analyze → elaborate → compile` inside a
> browser tab, see **[UnsignedChad/ghdl-browser](https://github.com/UnsignedChad/ghdl-browser)**.
>
> The two repos relate like this:
>
> | Repo | Role |
> | --- | --- |
> | [`ghdl-browser`](https://github.com/UnsignedChad/ghdl-browser) | The user-facing in-browser GHDL port. Analyzes VHDL, drives elaboration via `libghdl`, produces a runnable `sim.wasm` — all in the browser, no server round trip. **Start here if you want to *use* GHDL in a browser.** |
> | `ghdl-wasm` (this repo) | The Ada backend `ghdl-browser` ultimately depends on for WAT emission. **Start here if you want to *modify* how VHDL is lowered to WebAssembly** (case statements, signal assignments, etc.). |


Instead of emitting native machine code, `ghdl_wasm` emits [WebAssembly Text format (WAT)](https://webassembly.github.io/spec/core/text/index.html), which can be assembled into a `.wasm` binary and executed by any modern JavaScript runtime or browser engine.

---

## Status

| Component | Status |
|---|---|
| WAT emission from VHDL | Working |
| `wat2wasm` binary validation | Passing — 8/8 circuits |
| Browser JS harness | In progress |
| Full signal/process simulation | In progress |

---

## Test Results

All circuits tested produce valid `.wasm` binaries via `wat2wasm`. Debug output from the compiler goes to **stderr** only — stdout is clean WAT.

| Circuit | Analyze | Elab/WAT | wat2wasm | WASM Size | Notes |
|---------|:-------:|:--------:|:--------:|----------:|-------|
| `half_adder` | ✓ | ✓ | ✓ | 10,315 B | Combinational — XOR/AND |
| `full_adder` | ✓ | ✓ | ✓ | 11,559 B | All 8 input combos tested |
| `ripple4` | ✓ | ✓ | ✓ | 83,962 B | Structural — 4× full_adder, generate loop |
| `dff` | ✓ | ✓ | ✓ | 10,917 B | D flip-flop, synchronous reset |
| `counter4` | ✓ | ✓ | ✓ | 82,517 B | 4-bit up-counter, enable + reset |
| `mux4to1` | ✓ | ✓ | ✓ | 11,605 B | 4-to-1 mux, case statement |
| `shift_reg` | ✓ | ✓ | ✓ | 11,496 B | 8-bit SIPO shift register |
| `alu` | ✓ | ✓ | ✓ | 85,911 B | 4-bit ADD/SUB/AND/OR, `numeric_std` |

**Size pattern:** Simple combinational/sequential circuits produce ~10–12 KB binaries. Circuits that pull in `ieee.numeric_std` (ripple4, counter4, alu) produce ~82–86 KB because the full IEEE library is elaborated in.

---

## How It Works

Standard GHDL compiles VHDL to native code via one of three backends (LLVM, GCC, or mcode). This fork adds a fourth backend — `wasm` — that walks the same internal ortho IR and emits WAT s-expressions:

```
VHDL source
    └─► ghdl_wasm --elab-run  →  WAT (stdout)
                                      └─► wat2wasm  →  .wasm binary
                                                            └─► browser / Node.js
```

The WAT module imports a set of GRT (GHDL Runtime) functions from a JavaScript `env` object, which your harness must provide.

---

## ghdl-wasm server cost

The architecture above means the server only pays for **compile** — once that's done, the resulting `.wasm` runs entirely on the user's machine. Re-running with different stimulus, sweeping parameters, scrubbing a waveform — all zero server hits.

Compare against tools that simulate on the server (EDA Playground and similar), which pay for both compile *and* the full simulation duration per user, per run:

| Sim length              | EDA Playground server cost | ghdl-wasm server cost  | Advantage |
|-------------------------|----------------------------|------------------------|-----------|
| 1 µs                    | ~2 s                       | ~2 s                   | tied      |
| 1 ms                    | ~30 s                      | ~2 s                   | **15×**   |
| 100 ms                  | ~5 min                     | ~5 s                   | **60×**   |
| Parameter sweep (10×)   | 10× the sim cost           | 1× compile, 0× sim     | **100×+** |

The compiled `.wasm` is also content-addressable — identical VHDL source produces an identical binary, so a hash-keyed CDN cache turns repeat runs (same source, any user) into a 304. A server-side simulator can't cache the simulation itself; each user starts from zero.

The cost curve bends the opposite direction from a server-simulator model: as designs get bigger and simulations get longer, the per-user server cost stays roughly constant (compile time only) instead of growing with simulation duration.

---

## Building from Source

### Prerequisites

- GNAT (Ada compiler) — GCC ≥ 10 with Ada support, or GNAT FSF
- `gprbuild` (GNAT Project Manager)
- `wat2wasm` from the [WebAssembly Binary Toolkit (WABT)](https://github.com/WebAssembly/wabt) for validation

On Ubuntu/Debian:
```bash
sudo apt install gnat gprbuild
# Install wabt from https://github.com/WebAssembly/wabt/releases
```

### Clone and Configure

```bash
git clone https://github.com/UnsignedChad/ghdl-wasm.git
cd ghdl-wasm
./configure --with-ortho=wasm --prefix=/usr/local
```

### Build

```bash
gprbuild -P ghdl.gpr -j$(nproc)
```

The resulting binary is `ghdl_wasm` in the build directory.

### Install Standard Libraries

```bash
make install
```

Library files are installed to `$PREFIX/lib/ghdl/wasm/`.

---

## Usage

### 1. Analyze your VHDL sources

```bash
ghdl_wasm -a --std=93c my_design.vhd
ghdl_wasm -a --std=93c my_design_tb.vhd
```

### 2. Elaborate and emit WAT

```bash
LIBDIR=/usr/local/lib/ghdl/wasm
ghdl_wasm --elab-run --std=93c -P$LIBDIR my_design_tb > my_design_tb.wat
```

Stdout is clean WAT. Diagnostic messages go to stderr — redirect them separately if needed:
```bash
ghdl_wasm --elab-run --std=93c -P$LIBDIR my_design_tb > out.wat 2>out.log
```

### 3. Assemble to WASM

```bash
wat2wasm my_design_tb.wat -o my_design_tb.wasm
```

### 4. Run in the browser or Node.js

Your JavaScript harness must provide all imported GRT functions via an `env` object:

```js
const fs = require('fs');
const bytes = fs.readFileSync('my_design_tb.wasm');
const env = {
  __ghdl_stack2_allocate:        (n) => 0,
  __ghdl_stack2_mark:            () => 0,
  __ghdl_stack2_release:         (p) => {},
  __ghdl_check_stack_allocation: (n) => {},
  __ghdl_memcpy:                 (dst, src, n) => {},
  __ghdl_ieee_assert_failed:     (a, b, c, d) => { throw new Error('assert failed'); },
  __ghdl_i32_mod:                (a, b) => ((a % b) + b) % b,
  __ghdl_bound_check_failed:     (f, l) => { throw new Error('bound check failed'); },
  __ghdl_integer_32_index_check_failed: (a, b, c, d) => { throw new Error('index check'); },
  __ghdl_program_error:          (f, l, e) => { throw new Error('program error'); },
  __ghdl_process_wait_exit:      () => {},
  __ghdl_process_wait_timeout:   (t, l, r) => {},
  __ghdl_signal_direct_assign:   (s) => {},
  __ghdl_signal_read_driver:     (s, i) => 0,
  __ghdl_signal_read_port:       (s, i) => 0,
};
WebAssembly.instantiate(bytes, { env }).then(({ instance }) => {
  instance.exports._initialize?.();
});
```

---

## Repository Layout

```
src/ortho/wasm/
├── ortho_wasm.adb          # WAT emitter — main backend implementation
├── ortho_wasm.ads          # Type declarations
├── ortho_wasm.private.ads  # Private package internals
├── ortho_jit.adb           # Stub JIT driver (emits WAT then exits)
├── ortho_ident.adb/.ads    # Identifier table
└── ortho_nodes.ads         # Ortho IR node types

test/
├── half_adder.vhd / half_adder_tb.vhd
├── full_adder.vhd / full_adder_tb.vhd
├── ripple4.vhd    / ripple4_tb.vhd
├── dff.vhd        / dff_tb.vhd
├── counter4.vhd   / counter4_tb.vhd
├── mux4to1.vhd    / mux4to1_tb.vhd
├── shift_reg.vhd  / shift_reg_tb.vhd
├── alu.vhd        / alu_tb.vhd
└── RESULTS.md     # Detailed test results and bug notes
```

---

## Known Limitations

- **No executable entry point** — The WASM binary has no exported `main`. Process functions exist but require a simulation scheduler to drive them. In-browser execution is blocked until this is implemented.
- **`New_Alloca` is stubbed** — Returns null pointer; dynamic stack allocation not yet implemented.
- Signal initialization and scheduling are partially implemented.
- VHDL-2008 features are not tested with the wasm backend.

---

## Credits

**Charles Kennedy** — Florida State University  
WebAssembly backend design and implementation.

Based on [GHDL](https://github.com/ghdl/ghdl) by Tristan Gingold and contributors, licensed under the GNU General Public License v2.

AI coding assistance was used in the development of this project.

---

## License

This project inherits GHDL's license: [GNU General Public License v2](COPYING.md).
