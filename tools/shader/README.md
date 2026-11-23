# tools/shader — Ruby shaders to SPIR-V, WGSL and MSL

A fragment or vertex shader is written as plain Ruby methods and declared with
`shader_def`. `spinel-rb2spv` reads Spinel's own analysis of the file, emits
the methods once as MLIR `func` + `arith` (+ `math`), and lowers that one
emission two ways: to SPIR-V for the GPU, and to LLVM for a CPU reference
object. The SPIR-V is canonical. WGSL and MSL are naga's translations of it.
Ported from spinel-llvm `463d49dd` (its P006, experiments E133–E145); see
[provenance](../../docs/provenance.md).

## A shader

```ruby
shader_def :flat,
  fragment: { r: :frag2_r, g: :frag2_g, b: :frag2_b, a: 1.0 },
  varyings: { u: :f32, v: :f32 },
  target:   { format: :rgba8unorm },
  lanes:    [:wgsl, :msl],
  contract: { wgsl: :fused, msl: :separate },
  coord:    :keep

def frag2_r(u, v)
  u * 0.7 + v * 0.3
end
# ... frag2_g, frag2_b
```

- **One method per output channel.** The subset is `Float` scalars with
  `+ - * /`, `Math.sqrt` and constants. Strings, arrays, integers, other
  transcendental functions, a wrong arity and expressions nested deeper than
  the downstream compilers accept are refused with exit 3 and a TSV row naming
  the node, never compiled wrongly (`test/reject/`).
- **Two forms.** Without `vertex:`, a full-screen triangle and
  `varyings: { u: :f32, v: :f32 }` in 0..1. With `attributes:` and
  `vertex: { x:, y: }`, a vertex pipeline: each varying is a method of the
  attributes, and `uniforms:` gives scalar `f32` uniforms (`test/tri.rb`). A
  varying may instead name an attribute, which passes it through unchanged:
  `varyings: { vr: :ar }` (`test/pass.rb`).
- **Lanes and contraction.** `:wgsl` is always generated, and WGSL cannot stop
  the GPU from fusing multiply-adds, so its contract is fixed at `:fused`.
  `:msl` can choose. `:separate` writes `#pragma STDC FP_CONTRACT OFF` into
  the MSL, so no multiply-add is fused whatever the app's compile options say;
  `:fused` and `:frontend` leave it to the Metal compiler's `mathMode`.
- `coord: :keep` is required. naga flips y by default, and the generator
  passes `--keep-coordinate-space`.

## A texture

In the vertex pipeline form, a shader can sample one 2D texture:

```ruby
textures: { atlas: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } },
fragment: { r: :frag_r, g: :frag_g, b: :frag_b, a: :frag_a },
```

`coord:` names two declared varyings. The shell samples at Lod 0, and the four
`texel:` names become the last arguments of every fragment method, after the
varyings and uniforms. `a:` may name a method only with a texture. A number gives
a constant alpha and leaving it out gives 1.0, with or without one. The texture
is at group 0 binding 1 and its sampler at binding 2, and binding 0 stays the
uniform buffer's even when there is none. The sampler's filter and the blending
are the host's. The MSL lane is refused with a texture.
A textured shader has no CPU references (see [decision 0029](../../docs/decisions/0029-shader-textures.md)):
its output has a `textured` marker file and `ref.o` holds only the pure functions
that receive the texels. `spinel-shader-cmp` and `vcmp` refuse a marked directory.

## Use

```sh
tools/shader/spinel-rb2spv tools/shader/test/flat_msl.rb --out out --res 256
# out/flat/: shader.spv, shader.wgsl, shader.metal (with lanes: [:msl]),
#            sig.txt, sp_shader_table.h, and the CPU reference files
clang -O2 -fobjc-arc -framework Metal -framework Foundation \
  tools/shader/draw_metal.m -o draw_metal
./draw_metal out/flat/shader.metal default u8 flat.rgba 256 256
```

It needs `LLVM_PREFIX` (`mlir-opt`, `mlir-translate` and `clang` from the LLVM
release), `naga` and `spirv-val` on `PATH`, `vendor/spinel` built, and
`tools/contract/build/spinel-typedump` (`sh tools/contract/build.sh`). The
[installation record](../../docs/toolchains/shader-tools/INSTALLATION-RECORD.md)
lists the versions.

| File | What it is |
|---|---|
| `spinel-rb2spv` | the generator. It cross-checks `spinel --dump-ast` against `spinel-typedump` by node id and stops if they disagree, and checks that no `spirv` dialect is written outside the fixed shell |
| `draw_metal.m` | the Metal driver: compiles an MSL (or reads a `.metallib`) on the device, draws one full-screen pass off screen, writes the raw pixels |
| `draw.c` | the WebGPU driver, for wgpu-native (and, built with `-DR011_DAWN`, Dawn): WGSL or SPIR-V, optional vertex and uniform buffers, an optional RGBA8 texture, `rgba8`, `f32` or `r32u` targets |
| `spinel-shader-attrib` | attributes the GPU's multiply-add fusions by matching its f32 output against CPU builds of each fusion candidate |
| `spinel-shader-cmp`, `spinel-shader-vcmp` | compare GPU output with the CPU references |
| `run_shader_gate.sh`, `golden/` | spinel-llvm's gate and its frozen digests |
| `test/` | the subjects, the vertex scenes and the refusal cases |

## Checks

`sh tests/shader/run.sh` checks the lane against its own contract on this
machine's GPU:

- the six subjects compile, their SPIR-V passes `spirv-val`, naga converts it,
  and the emission check holds;
- adding the MSL lane leaves the SPIR-V byte-identical, and `:separate` writes
  its pragma;
- every refusal case exits 3; a textured shader's output is marked and has no
  CPU references, and `spinel-shader-cmp` and `vcmp` refuse a marked directory
  (the suite runs only this refusal, and, as its control, the tools on an empty
  directory, where they stop at their missing inputs and compare nothing);
- Metal compiles the generated MSL and draws with it, under `:separate` and
  `:fused`, and refuses a broken MSL;
- through wgpu-native, the fragment subjects draw; `tri.rb`'s quad covers
  exactly the pixels its scene's vertices enclose, and the coverage shader
  gives both triangles' ids over them; a new uniform alone changes the image;
  a 2x2 texture gives hand-written RGBA at interior pixels, including a colour
  and a faint branch and a shader with no uniform, and three planted faults
  are seen.

**Kept as files and not run, because they are oracles** (they compare with
another implementation): `spinel-shader-cmp`, `spinel-shader-vcmp`,
`spinel-shader-attrib`, the CPU references the generator writes (`ref.o`,
`ref_c.c`, `ref_native.rb`, `raster_ref.c`), `golden/`, and
`run_shader_gate.sh`. The gate also expects spinel-llvm's wgpu-native and Dawn
under `docs/researches/r010_probes/vendor`, which this repository does not
have.

## Compute kernels

`spinel-rb2comp` compiles a Ruby compute kernel, not a shader. One body goes
through MLIR to WGSL for WebGPU, MSL for Metal and PTX for CUDA; decision
[0031](../../docs/decisions/0031-gpu-compute-route.md) is the contract.

```sh
tools/shader/spinel-rb2comp kernel.rb --out out                # the WebGPU host
CUDA_PATH=/path/to/cuda-toolkit \
  tools/shader/spinel-rb2comp kernel.rb --out out --host cuda  # the CUDA host
tools/shader/spinel-rb2comp kernel.rb --out out --host metal   # the Metal host, on macOS
```

It writes `out/<unit>/`: `emission.mlir`, `shader.spv`, `kernel.wgsl`,
`kernel.metal`, `kernel.ptx`, `layout.tsv`, `sig.txt` and `<unit>_host.rb`, whose module has
`open`, `dispatch`, `close` and `<buffer>_write` or `<buffer>_read`. A refused
kernel exits 3 and `out/reject.tsv` says why.

The kernel must be compiled with the same `--host` as the program that uses it.
A CUDA program links `libcuda`; a Metal program links the Metal framework; a
WebGPU program is built with
`tools/wasm/spinel-wasm --host-api` and given
`makeComputeApi` from `tools/wasm/compute_host.mjs`.

## Limits

- **No `.metallib` and no AIR check.** This machine has no Metal toolchain, and
  installing one would change a shared Xcode component. MSL is compiled on the
  device at run time; spinel-llvm's AIR-level check that `:separate` leaves no
  fast-math flag needs `xcrun metal`, so it is not run.
- **v1 scalars only**: `f32` attributes, varyings and uniforms, one colour
  target, RGB plus a constant alpha (or a method, with a texture), a 2D vertex
  position.
