# E094: scx_simple equivalent — Ruby で書いた CPU scheduler。

class SimpleScx < BPF::SchedExt
  def enqueue(p, enq_flags)
    scx_dispatch(p, SCX::DSQ::GLOBAL, SCX::SLICE_DFL, enq_flags)
  end

  def dispatch(cpu, prev)
    scx_consume(SCX::DSQ::GLOBAL)
  end

  def init
    0
  end
end
