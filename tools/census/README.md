# tools/census -- boxing census and codegen audit

Ported from spinel-llvm `463d49dd` (E116, E118); see
[provenance](../../docs/provenance.md).

## The boxing census

`spinel-boxing-census` counts, per program, what the generated C (`spinel -S`)
spends on dynamic typing: `sp_poly_*(` dispatches, `sp_RbVal` slots and
`sp_box_*(` calls. It is looser than a byte comparison, so an intended change
passes and a program that gets more boxed shows up. A program whose emission
fails is recorded as `EMIT-FAIL`, never as a zero.

```sh
ruby tools/census/spinel-boxing-census take now.tsv [corpus...]   # default: vendor/spinel test/ and benchmark/
ruby tools/census/spinel-boxing-census gate base.tsv now.tsv
```

On Debian 13 at the pinned Spinel, `take` over the default corpus reads 3,758
programs in 36 s, none `EMIT-FAIL`.

`run_census_gate.sh` and `baseline/` compare against counts recorded with
spinel-llvm's own Spinel pin (`bd2d276a`) and its `doom/` sources, which are
not here: an oracle, kept as files, run only on the user's instruction. A
baseline of this repository's own is taken with `take`.

## Not runnable at this pin

- `spinel-codegen-audit` reads two sidecars that spinel-llvm's Spinel fork
  wrote under vendor patches L2 (`SPINEL_LLVM_TYPES_NODE_ID`, `--emit-types`)
  and L3/L4 (`SPINEL_LLVM_CODEGEN_FACTS`, the boxing facts). The pinned Spinel
  has none of them, so the audit has nothing to read.
- `spinel-boxing-census where` needs L2 as well.
- `emit_c_hashes.sh` hashes each program's generated C, to show that a vendor
  patch changes no output while its flag is unset. There is no vendor patch
  here to check.
