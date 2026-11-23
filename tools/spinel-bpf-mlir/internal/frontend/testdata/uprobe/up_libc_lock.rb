require "bpf"

# P029 E157: uprobe の pointer の引数 (:ptr — raw の i64) — libc の pthread_mutex_lock(pthread_mutex_t *mutex) の mutex を thread ごとの Held に、
# 前に持った mutex が在れば辺 (from → to) を Edges に。pthread_mutex_unlock は引数を読まずに Held を 0 に (1 段の近似 — deadlock の形)。
E = Struct.new(:pid_tgid, :from, :to)
BPF.record(E, pid_tgid: :u64, from: :i64, to: :i64)
Edges = BPF::RingBuf.new("Edges", E.new(0, 0, 0), 65536)
Held = BPF::HashMap.new("Held", :i64, :i64, 10240)
Out = BPF::ArrayMap.new("Out", :i64, 3)

def on_lock(ctx)
  tid = BPF.pid_tgid & 0xFFFF_FFFF
  m = ctx.arg(1)
  prev = Held.lookup(tid)
  if prev
    p = prev.load
    if p != 0
      if Edges.output(E.new(BPF.pid_tgid, p, m))
        Out.atomic_add(1, 1)
      else
        Out.atomic_add(2, 1)
      end
    end
  end
  _ = Held.update(tid, m)
  Out.atomic_add(0, 1)
end
BPF.uprobe :on_lock, "/lib/x86_64-linux-gnu/libc.so.6", "pthread_mutex_lock", params: {1 => :ptr}

def on_unlock(ctx)
  _ = Held.update(BPF.pid_tgid & 0xFFFF_FFFF, 0)
end
BPF.uprobe :on_unlock, "/lib/x86_64-linux-gnu/libc.so.6", "pthread_mutex_unlock", params: {}
