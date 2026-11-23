// XDP skeleton lowers program to llvm.func/section, verdict to result, and packet.load to bounds
// checks.
//
// RUN: spbpf-opt --convert-spbpf-to-llvm %s | FileCheck %s
// No SpBPF operations may remain, and LLVM IR translation must succeed:
// RUN: spbpf-opt --convert-spbpf-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts %s \
// RUN:   | mlir-translate --mlir-to-llvmir | FileCheck --check-prefix=IR %s
//
// An unregistered pass must fail; system mlir-opt does not know SpBPF:
// RUN: not mlir-opt --convert-spbpf-to-llvm %s 2>&1 | FileCheck --check-prefix=UNREG %s
// UNREG: {{.*}}convert-spbpf-to-llvm

// program becomes llvm.func with attach-kind section.
// CHECK: llvm.func @pass_all(%{{.*}}: !llvm.ptr) -> i32 attributes {section = "xdp"}
// CHECK-NOT: spbpf.
// IR: define i32 @pass_all(ptr %{{.*}}) section "xdp"
spbpf.program @pass_all "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  // verdict becomes xdp_action, pass=2.
  // CHECK: llvm.mlir.constant(2 : i32)
  // CHECK: llvm.return
  // IR: ret i32 2
  spbpf.verdict "pass"
}

// CHECK-LABEL: llvm.func @drop_all
spbpf.program @drop_all "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  // CHECK: llvm.mlir.constant(1 : i32)
  spbpf.verdict "drop"
}

// packet.load checks data/data_end bounds and returns zero when outside, rather than an unchecked
// read rejected by the kernel verifier.
// CHECK-LABEL: llvm.func @read_first_byte
// CHECK: llvm.getelementptr
// CHECK: llvm.load
// CHECK: llvm.icmp "ule"
// CHECK: llvm.cond_br
// IR-LABEL: define i32 @read_first_byte
// IR: icmp ule ptr
// IR: phi i32
spbpf.program @read_first_byte "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %off = arith.constant 0 : i32
  %b = spbpf.packet.load %ctx[%off] : !spbpf.ctx<"xdp">, i32 -> i32
  spbpf.verdict "pass"
}
