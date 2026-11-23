// E283 case a_two_c5_end — 同じ添字 i の 2 つの ref.index (mojo-bpf-mlir E046 の a_two の ebpf の形)。hist は [5 x u32] @4、record の大きさ 24 (end)
ebpf.program @prog "xdp" maps [@aa, @ap, @out] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %aa: !ebpf.map<"array", i32, !ebpf.record<"R", 24>>, %ap: !ebpf.map<"array", i32, !ebpf.record<"R", 24>>, %out: !ebpf.map<"array", i32, i64>):
  %c0 = arith.constant 0 : i32
  %c4 = arith.constant 4 : i32
  %ok, %k, %i, %n = ebpf.packet.check %ctx[%c0] len 4 : !ebpf.ctx<"xdp">, i32 -> i1, i32, i32, i32 in_range {
  ^w(%w: !ebpf.pkt_window<4>):
    %t = arith.constant true
    %b0 = ebpf.packet.window_load %w[0] : !ebpf.pkt_window<4> -> i8
    %b1 = ebpf.packet.window_load %w[1] : !ebpf.pkt_window<4> -> i8
    %b3 = ebpf.packet.window_load %w[3] : !ebpf.pkt_window<4> -> i8
    %k8 = arith.extui %b0 : i8 to i32
    %m3 = arith.constant 3 : i32
    %kk = arith.andi %k8, %m3 : i32
    %ii = arith.extui %b1 : i8 to i32
    %nn = arith.extui %b3 : i8 to i32
    ebpf.yield %t, %kk, %ii, %nn : i1, i32, i32, i32
  } out_of_range {
    %f = arith.constant false
    %z = arith.constant 0 : i32
    ebpf.yield %f, %z, %z, %z : i1, i32, i32, i32
  }
  ebpf.if %ok {
    
    %p = ebpf.map.lookup %aa[%k] : !ebpf.map<"array", i32, !ebpf.record<"R", 24>>, i32 -> !ebpf.maybe_ref<!ebpf.record<"R", 24>>
    ebpf.ref.check %p : !ebpf.maybe_ref<!ebpf.record<"R", 24>> present {
    ^p(%b: !ebpf.borrowed<!ebpf.record<"R", 24>>):
      ebpf.ref.index %b "hist" [%i] : !ebpf.borrowed<!ebpf.record<"R", 24>>, i32 in_range {
      ^e(%e: !ebpf.elem<i32>):
        ebpf.elem.store %e, %n : !ebpf.elem<i32>, i32
        ebpf.yield
      } out_of_range {
        ebpf.yield
      }
      ebpf.yield
    } absent {
      ebpf.yield
    }
    %q = ebpf.map.lookup %ap[%c0] : !ebpf.map<"array", i32, !ebpf.record<"R", 24>>, i32 -> !ebpf.maybe_ref<!ebpf.record<"R", 24>>
    ebpf.ref.check %q : !ebpf.maybe_ref<!ebpf.record<"R", 24>> present {
    ^q(%b2: !ebpf.borrowed<!ebpf.record<"R", 24>>):
      ebpf.ref.index %b2 "hist" [%i] : !ebpf.borrowed<!ebpf.record<"R", 24>>, i32 in_range {
      ^e2(%e2: !ebpf.elem<i32>):
        %v = ebpf.elem.load %e2 : !ebpf.elem<i32> -> i32
        %one = arith.constant 1 : i32
        %v1 = arith.addi %v, %one : i32
        ebpf.elem.store %e2, %v1 : !ebpf.elem<i32>, i32
        ebpf.yield
      } out_of_range {
        ebpf.yield
      }
      ebpf.yield
    } absent {
      ebpf.yield
    }
    
    ebpf.if.yield
  } else {
    ebpf.if.yield
  }
  ebpf.verdict "pass"
}
