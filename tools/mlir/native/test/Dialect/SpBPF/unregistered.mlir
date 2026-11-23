// Parsing must fail without SpBPF registration. foundation-roundtrip intentionally registers only
// func/arith/cf/scf; this controls the claim that registration enables acceptance.
// RUN: not spinel-mlirgen --foundation-roundtrip %s 2>&1 | FileCheck %s

// CHECK: error
// CHECK-SAME: spbpf
spbpf.program @nope "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  spbpf.verdict "pass"
}
