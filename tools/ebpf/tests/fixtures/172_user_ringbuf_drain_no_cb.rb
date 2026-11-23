# E414 negative fixture: `user_ringbuf_drain` with no callback declared.
#
# The drain lowers to `bpf_user_ringbuf_drain(&bpf_user_cmds, <callback>, ...)`
# and there is no callback to name. The retired Ruby oracle refused this too
# (codegen_bpf.rb: "declare a `def user_ringbuf__<name>(value)` callback first");
# E414 keeps the refusal and says what to write.
@pkts = 0

def xdp__pump
  @pkts = @pkts + 1
  user_ringbuf_drain
  XDP_PASS
end
