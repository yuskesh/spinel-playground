// Lower record reservation, field writes, ktime and ref.store to LLVM dialect.
//
// RUN: spbpf-opt --convert-spbpf-to-llvm %s | FileCheck %s
// RUN: spbpf-opt --convert-spbpf-to-llvm --convert-arith-to-llvm --reconcile-unrealized-casts %s \
// RUN:   | mlir-translate --mlir-to-llvmir | FileCheck --check-prefix=IR %s

// CHECK-LABEL: llvm.func @emit_record
// IR-LABEL: define i32 @emit_record
spbpf.program @emit_record "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  // Reserve the thirty-two bytes embedded in the record type, not a silent eight-byte default for
  // noninteger types. Reserve helper is 131.
  // CHECK-DAG: llvm.mlir.constant(32 : i64)
  // CHECK-DAG: llvm.mlir.constant(131 : i64)
  // IR: call ptr inttoptr (i64 131 to ptr)
  %r = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<!spbpf.record<"pair_event", 32>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"pair_event", 32>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"pair_event", 32>>):
    // ktime uses helper 5, known only to lowering.
    // CHECK: llvm.mlir.constant(5 : i64)
    // IR: call i64 inttoptr (i64 5 to ptr)
    %ts = spbpf.ktime.ns : i64
    // Field writes become byte-offset GEP plus store.
    // CHECK: llvm.getelementptr %{{.*}}[8]
    // CHECK: llvm.store
    spbpf.ringbuf.store_field %res[8], %ts : !spbpf.reservation<!spbpf.record<"pair_event", 32>>, i64
    // CHECK: llvm.getelementptr %{{.*}}[16]
    // CHECK: llvm.store
    %a = arith.constant 7 : i64
    spbpf.ringbuf.store_field %res[16], %a : !spbpf.reservation<!spbpf.record<"pair_event", 32>>, i64
    // CHECK: llvm.mlir.constant(132 : i64)
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"pair_event", 32>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  // CHECK-NOT: spbpf.
  spbpf.verdict "pass"
}

// ref.store lowers to store through a borrowed raw pointer; percpu_array is also admitted for lost
// counters.
// CHECK-LABEL: llvm.func @bump_lost
// IR-LABEL: define i32 @bump_lost
spbpf.program @bump_lost "xdp" maps [@lost] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %lost: !spbpf.map<"percpu_array", i32, i64>):
  %k = arith.constant 0 : i32
  // CHECK: llvm.mlir.constant(1 : i64)
  %p = spbpf.map.lookup %lost[%k]
      : !spbpf.map<"percpu_array", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  spbpf.ref.check %p : !spbpf.maybe_ref<i64> present {
  ^present(%ref: !spbpf.borrowed<i64>):
    %cur = spbpf.ref.load %ref : !spbpf.borrowed<i64> -> i64
    %one = arith.constant 1 : i64
    %next = arith.addi %cur, %one : i64
    // CHECK: llvm.store
    // IR: store i64
    spbpf.ref.store %ref, %next : !spbpf.borrowed<i64>, i64
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
