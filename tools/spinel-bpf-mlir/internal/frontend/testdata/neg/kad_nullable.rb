require "bpf"

# P029 E155: 検査済みの kernel pointer の address (bpf-mlir E554 の ebpf.kptr.addr) — fentry blk_mq_start_request の request (present の q) の q.addr を
# Starts の key に、Filter の tgid の start の {addr, sector: __sector, len: __data_len} を Last[0] に、Out[0] に start の数。fentry blk_mq_end_request は
# Filter の窓の中の end の key が Starts に在れば Out[1] (join)、無ければ Out[2] (他の request の end)。NVMe の batch の完了は blk_mq_end_request を通らない
Rq = Struct.new(:__data_len, :__sector)
BPF.kernel_type(Rq, "request", __data_len: :u32, __sector: :u64)
RqT = BPF::KernelType.new(Rq.new(0, 0))

Ev = Struct.new(:addr, :sector, :len, :pad)
BPF.record(Ev, addr: :i64, sector: :u64, len: :u32, pad: :u32)
Filter = BPF::ArrayMap.new("Filter", :u32, 1)
Out = BPF::ArrayMap.new("Out", :i64, 4)
Starts = BPF::HashMap.new("Starts", :i64, :u64, 1024)
Last = BPF::RecordMap.new("Last", Ev.new(0, 0, 0, 0), 1)
def on_start(ctx)
  q = ctx.kptr_or_null(0, RqT)
  Out.update(0, q.addr)
end
BPF.fentry :on_start, "blk_mq_start_request", args: {0 => [:or_null, RqT]}
# want: SB005 17:3
