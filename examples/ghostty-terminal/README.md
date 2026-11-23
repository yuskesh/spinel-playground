# ghostty-terminal

A terminal in the browser, written in Ruby and compiled to WebAssembly. By
default a small shell runs inside the module, with no PTY and no server; `bridge`
connects the same page to a real shell on your machine. libghostty-vt
parses the terminal stream, Ruby decides what to draw, and WebGPU draws it with
two shaders that `tools/shader` generates from `shader/quad.rb` and
`shader/glyph.rb`.

This is a prototype. It draws only
the first codepoint of a combining sequence, and needs a browser with WebGPU and
WebAssembly JSPI. The C ABI of libghostty-vt is stable only from Ghostty 1.0, so
this example is tied to the revision below.

## Build

Ghostty is not part of this repository. Build libghostty-vt with Zig 0.17.0 from
commit `711702d572cfef2897b898d7147050fc6808f6e6`:

```sh
zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall
```

Then, with `vendor/spinel` and `tools/contract` built:

```sh
export LLVM_PREFIX=... WASI_SYSROOT=... WASI_BUILTINS=... GHOSTTY_DIR=...
examples/ghostty-terminal/build.sh OUT
```

Serve `OUT/web` with any static HTTP server that gives `.wasm` the type
`application/wasm`, and open it on `localhost`: WebGPU needs a secure context,
which `localhost` is. `help` lists the shell's commands.

## A shell on this machine

The build also makes `OUT/bridge`, a native program compiled by Spinel from
`bridge.rb`:

```sh
OUT/bridge OUT/web          # or: OUT/bridge OUT/web PORT
```

It prints a URL with this run's token; open that URL. It serves the page, starts
`$SHELL -l` on a PTY when the page connects, and carries the bytes over a
WebSocket. One shell at a time, and closing the page ends it.

Anyone who reaches that WebSocket has your shell. It listens on 127.0.0.1 only
and requires the token, a local `Host` and a local `Origin`; treat the URL as a
password. Pasting and mouse reporting are not implemented.

## Fonts

The page uses an installed Nerd Font if it finds one of JetBrainsMono, MesloLGS,
Hack or FiraCode, because prompt icons such as Starship's exist only in those
fonts. For any other font, add `&font=NAME` to the URL with the installed family
name. Nothing is bundled, so without a Nerd Font those icons do not draw.

## Size and history

The grid follows the window, and the shell is told through the PTY. The page's
`?size=COLSxROWS` asks for a fixed grid instead.

The mouse wheel moves through up to 10,000 lines of history, as do Shift+PageUp,
Shift+PageDown, Shift+Home and Shift+End. Typing returns to the bottom. A program
on the alternate screen, such as `less` or `vim`, has no history to move through
and does not receive the wheel.

## Files

| File | What it is |
|---|---|
| `shell.rb`, `life.rb` | the shell and the Game of Life it runs |
| `remote.rb`, `bridge.rb` | the terminal's side of a real shell, and the native bridge to it |
| `display.rb` | the screen: glyph placement in the atlas, one `Tile` per cell, the two vertex buffers |
| `ghostty.rb`, `keys.rb` | a Ruby API over libghostty-vt, and the key table generated from its header |
| `host.c` | the imports from the page, and what a Ruby FFI signature cannot express |
| `web/main.mjs` | the browser's side: WebGPU, the font rasterizer, the keyboard |

## Checks

`sh tests/ghostty-terminal/run.sh` builds the page and checks real pixels in
headless Chromium, drawing off screen, then runs commands through the bridge
and checks its refusals. Presenting to a canvas loses the device
with a software adapter, so the canvas itself is not covered there.

## Notices

The built `shell.wasm` contains libghostty-vt, and `keys.rb` is generated from
its header. Ghostty is under the MIT license, copyright Mitchell Hashimoto,
Ghostty contributors. A distributed build must carry that notice.
