// E254 case idx_const — ix の lookup が失敗したときの既定の添字が定数 0 — 同じ ref.index の加算に定数と未知の値の両方が届く (x_load の 1 つ分)
ebpf.program @prog "xdp" maps [@nests, @ix, @out] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %nests: !ebpf.map<"array", i32, !ebpf.record<"outer", 40>>, %ix: !ebpf.map<"array", i32, i64>, %out: !ebpf.map<"array", i32, i64>):
  %k0 = arith.constant 0 : i32
  %k1 = arith.constant 1 : i32
  %mj = ebpf.map.lookup %ix[%k0] : !ebpf.map<"array", i32, i64>, i32 -> !ebpf.maybe_ref<i64>
  %xj = ebpf.ref.check %mj : !ebpf.maybe_ref<i64> -> i64 present {
  ^p(%r: !ebpf.borrowed<i64>):
    %v = ebpf.ref.load %r : !ebpf.borrowed<i64> -> i64
    ebpf.yield %v : i64
  } absent {
    %z = arith.constant 0 : i64
    ebpf.yield %z : i64
  }
  %i = arith.trunci %xj : i64 to i32
  %m = ebpf.map.lookup %nests[%k1] : !ebpf.map<"array", i32, !ebpf.record<"outer", 40>>, i32 -> !ebpf.maybe_ref<!ebpf.record<"outer", 40>>
  ebpf.ref.check %m : !ebpf.maybe_ref<!ebpf.record<"outer", 40>> present {
  ^p(%b: !ebpf.borrowed<!ebpf.record<"outer", 40>>):
    %v0 = ebpf.ref.index %b "arr" [%i] : !ebpf.borrowed<!ebpf.record<"outer", 40>>, i32 -> i64 in_range {
    ^e(%e: !ebpf.elem<i16>):
      %x = ebpf.elem.load %e : !ebpf.elem<i16> -> i16
      %w = arith.extui %x : i16 to i64
      ebpf.yield %w : i64
    } out_of_range {
      %s = arith.constant 999 : i64
      ebpf.yield %s : i64
    }
    ebpf.map.update %out[%k0], %v0 : !ebpf.map<"array", i32, i64>, i32, i64
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "pass"
}
