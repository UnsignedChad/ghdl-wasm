# ghdl-wasm

A fork of [GHDL](https://github.com/ghdl/ghdl) that adds a **WebAssembly (WASM) backend**, enabling VHDL designs to be compiled and simulated directly in the browser.

Instead of emitting native machine code, `ghdl_wasm` emits [WebAssembly Text format (WAT)](https://webassembly.github.io/spec/core/text/index.html), which can be assembled into a `.wasm` binary and executed by any modern JavaScript runtime or browser engine.
---

## Status

| Component | Status |
|---|---|
| WAT emission from VHDL | Working |
| `wat2wasm` binary validation | Passing |
| Browser JS harness | In progress |
| Full signal/process simulation | In progress |

Tested with `half_adder` and `half_adder_tb` — produces a valid ~10 KB `.wasm` binary.

---

## How It Works

Standard GHDL compiles VHDL to native code via one of three backends (LLVM, GCC, or mcode). This fork adds a fourth backend — `wasm` — that walks the same internal ortho IR and emits WAT s-expressions:

```
VHDL source
    └─► ghdl_wasm --elab-run  →  WAT (stdout)
                                      └─► wat2wasm  →  .wasm binary
                                                            └─► browser / Node.js
```

The WAT module imports a small set of GRT (GHDL Runtime) functions from a JavaScript `env` object, which your harness must provide.

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
./configure --prefix=/usr/local
```

### Build the WASM Backend

```bash
# Configure for the wasm ortho backend
./configure --with-ortho=wasm --prefix=/usr/local

# Build
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

This writes the full WebAssembly Text module to stdout.

### 3. Assemble to WASM

```bash
wat2wasm my_design_tb.wat -o my_design_tb.wasm
```

### 4. Run in the browser or Node.js

Your JavaScript harness must provide the imported GRT functions via an `env` import object. Example (Node.js):

```js
const fs = require('fs');
const bytes = fs.readFileSync('my_design_tb.wasm');
const env = {
  __ghdl_process_wait_exit:      () => {},
  __ghdl_process_wait_timeout:   (t, l, r) => {},
  __ghdl_signal_direct_assign:   (s) => {},
  __ghdl_signal_read_port:       (s, i) => 0,
  __ghdl_signal_read_driver:     (s, i) => 0,
  __ghdl_stack2_allocate:        (n) => 0,
  __ghdl_memcpy:                 (dst, src, n) => {},
  __ghdl_bound_check_failed:     (f, l) => { throw new Error('bound check failed'); },
  __ghdl_integer_32_index_check_failed: (a, b, c, d) => { throw new Error('index check failed'); },
  __ghdl_program_error:          (f, l, e) => { throw new Error('program error'); },
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
├── half_adder.vhd          # Example design
└── half_adder_tb.vhd       # Example testbench
```

The rest of the tree is the upstream GHDL source. See the [GHDL documentation](https://ghdl.github.io/ghdl) for details on the analyzer, elaboration model, and VHDL standard support.

---

## Known Limitations

- `New_Alloca` (stack allocation) is stubbed — returns a null pointer. Designs that use dynamic stack allocation will need this fixed before they produce correct results.
- Signal initialization and scheduling are partially implemented. Simple combinational designs work; full process/signal scheduling is in progress.
- No export declarations yet — the elaboration entry point must be called manually from the JS harness.
- VHDL-2008 features are not tested with the wasm backend.

---

## Credits

**Charles Kennedy** — Florida State University  
WebAssembly backend design and implementation.

Based on [GHDL](https://github.com/ghdl/ghdl) by Tristan Gingold and contributors, licensed under the GNU General Public License v2.

AI coding assistance was used in the development of this project (`src/ortho/wasm/`).

---

## License

This project inherits GHDL's license: [GNU General Public License v2](COPYING.md).
