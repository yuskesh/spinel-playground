// Map/ring-buffer lowering: map args become .maps-global addressof relocations; helpers become
// constant-function-pointer indirect calls as in libbpf; ref.check becomes actual null control
// flow.
//
// Only the lowering target profile owns helper numbers, not dialect or schema.
//
// RUN: spbpf-opt --convert-spbpf-to-llvm %s | FileCheck %s
// RUN: spbpf-opt --convert-spbpf-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts %s \
// RUN:   | mlir-translate --mlir-to-llvmir | FileCheck --check-prefix=IR %s

// Maps become .maps globals.
// CHECK-DAG: llvm.mlir.global external @counts() {{.*}}section = ".maps"
// CHECK-DAG: llvm.mlir.global external @events() {{.*}}section = ".maps"
// IR-DAG: @counts = external global {{.*}}section ".maps"
// IR-DAG: @events = external global {{.*}}section ".maps"

// CHECK-LABEL: llvm.func @count_and_emit
spbpf.program @count_and_emit "xdp" maps [@counts] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"array", i32, i64>):
  %k = arith.constant 0 : i32

  // ARRAY atomic counter: lookup, null check, atomicrmw.
  // CHECK: llvm.mlir.addressof @counts
  // CHECK: llvm.inttoptr
  // CHECK: llvm.call
  // CHECK: llvm.icmp "ne"
  // CHECK: llvm.atomicrmw add
  // IR: call ptr inttoptr (i64 1 to ptr)
  // IR: atomicrmw add ptr
  %one = arith.constant 1 : i64
  spbpf.map.atomic_add %m[%k], %one : !spbpf.map<"array", i32, i64>, i32, i64

  // lookup/ref.check lowers to a null branch.
  // CHECK: llvm.icmp "ne"
  // CHECK: llvm.cond_br
  // CHECK: llvm.load
  // IR: icmp ne ptr
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %zero = arith.constant 0 : i64
  %cur = spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> -> i64 present {
  ^present(%ref: !spbpf.borrowed<i64>):
    %v = spbpf.ref.load %ref : !spbpf.borrowed<i64> -> i64
    spbpf.yield %v : i64
  } absent {
    spbpf.yield %zero : i64
  }

  // Ring buffer reserve/submit use helpers 131/132, known only to lowering.
  // CHECK: llvm.mlir.constant(131 : i64)
  // CHECK: llvm.mlir.constant(132 : i64)
  // IR: inttoptr (i64 131 to ptr)
  // IR: inttoptr (i64 132 to ptr)
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ringbuf.store %r, %cur : !spbpf.reservation<i64>, i64
    spbpf.ringbuf.submit %r : !spbpf.reservation<i64>
    spbpf.yield
  } absent {
    spbpf.yield
  }

  // CHECK-NOT: spbpf.
  spbpf.verdict "pass"
}
