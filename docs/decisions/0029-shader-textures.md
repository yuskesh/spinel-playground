# 0029: Texture sampling and a varying alpha in tools/shader

- Date: 2026-11-09
- Status: Accepted by the owner on 2026-11-09, including the drawing check on
  the Mac and the entry refusals of `spinel-shader-cmp` and
  `spinel-shader-vcmp` in the routine suite.
- Scope: `tools/shader`, for a glyph shader written in Ruby. One 2D texture
  sampled at Lod 0, and an alpha computed by a method.

## Decision

`shader_def` accepts `textures: { name: { coord: [:u, :v], texel: [:tr, :tg, :tb, :ta] } }`
in the vertex pipeline form. The shell samples once with `ImageSampleExplicitLod`
at Lod 0, and the four components are passed to the fragment methods as Float
arguments after the varyings and uniforms. `emission.mlir` stays func and arith,
and the subset is unchanged: no integers, branches, or arrays.

- The uniform, texture and sampler sit at group 0 bindings 0, 1 and 2, and the
  numbers are not closed up when there is no uniform.
- `fragment: { a: :method }` is honoured with a texture. Without one it is now
  refused: the method used to be accepted and silently ignored, with alpha 1.
- The sampler, its filter and the blending belong to the host. The generator
  does not declare them.
- `:msl` is refused with a texture, because `draw_metal.m` has no texture path.

## A textured shader has no CPU reference

`ref_native.rb`, `ref_c.c`, `ref_driver.c` and `raster_ref.c` are not generated.
`ref.o` is still built, and holds only the pure functions that receive the
texels; it says nothing about sampling or the whole shader, and the tolerance in
`sp_shader_table.h` covers the arithmetic only. Lowering the sampling to the CPU
is not part of this decision.

The comparison tools take a directory and do not read the declaration, so the
generator puts a file named `textured` in the shader's output directory.
`spinel-shader-cmp` and `spinel-shader-vcmp` refuse a directory that has it,
before reading anything. When a directory is reused, a textured build writes the
marker before rewriting anything, and a plain build removes it only after a
complete build, so a failure cannot leave textured output unmarked.
`spinel-shader-attrib` refuses a textured declaration before it seeds. That
refusal is implemented but has not been run: the owner's approval for routine
tests named only `spinel-shader-cmp` and `spinel-shader-vcmp`.

The signature keeps its form. For a textured shader the normalized declaration
is added to its text, because `decl_text` stops at the first line that does not
end in a comma and would cut off a multi-line `textures:`. Declarations without a
texture hash the same text as before. The signature does not cover the host's
texels, format or sampler.

## What the check proves

`tests/shader/run.sh` draws through wgpu-native with a 2x2 nearest texture and
compares raw RGBA at interior pixels with values written by hand in the test, so
it is not a comparison with another implementation. Planted faults (the sampled
alpha dropped, two texel arguments exchanged, u and v exchanged) must be seen. It
accepts the sampling feature. It claims nothing about other filters or about
equivalence with a CPU exit.
