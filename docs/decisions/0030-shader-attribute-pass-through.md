# 0030: Passing an attribute through as a varying in tools/shader

- Date: 2026-11-09
- Status: Requested by the owner on 2026-11-09.
- Scope: the vertex pipeline form of `shader_def`.

## Decision

A value in `varyings:` may name an attribute: `varyings: { vr: :ar }` means that
`vr` is `ar`, unchanged. Without this, every such varying needed a method that
took all the attributes and uniforms and returned one of them.

The generator writes that method itself, in the copy of the source it analyses
and in the CPU reference. Everything downstream, including the subset check, the
typing and the emitted shader, treats it as an ordinary method, so the output
is the same as for the method written out (`tests/shader/run.sh` compares them).

- A method with the same name as the attribute is refused when a varying names
  it, because the varying could mean either. This form used to be accepted and
  to call the method, so such a shader must now rename one of them.
- A uniform is refused unless a method has its name: a fragment method already
  receives the uniforms.
- `fragment:` is unchanged: a fragment output that returns a varying as it stands
  is still written as a method.
