// CFG checking refuses path-dependent reservation consumption.
//
// The original verifier counted uses only, so partial below looked like one submit and passed. This
// test checks the previously documented gap.
//
// RUN: spbpf-opt %s -o /dev/null
// RUN: not spbpf-opt --spbpf-verify-ownership %s 2>&1 | FileCheck %s

// CHECK: 'spbpf.ref.check' op a ring buffer reservation is consumed in only some of this operation's regions
spbpf.program @partial "xdp" maps [@m] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %m: !spbpf.map<"hash", i32, i64>):
  %k = arith.constant 0 : i32
  %maybe = spbpf.map.lookup %m[%k]
      : !spbpf.map<"hash", i32, i64>, i32 -> !spbpf.maybe_ref<i64>
  %res = spbpf.ringbuf.reserve "events" : !spbpf.maybe_reservation<i64>
  spbpf.ringbuf.if_reserved %res : !spbpf.maybe_reservation<i64> present {
  ^present(%r: !spbpf.reservation<i64>):
    spbpf.ref.check %maybe : !spbpf.maybe_ref<i64> present {
    ^present(%ref: !spbpf.borrowed<i64>):
      spbpf.ringbuf.submit %r : !spbpf.reservation<i64>
      spbpf.yield
    } absent {
      spbpf.yield
    }
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
