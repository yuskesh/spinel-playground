// Program using the real predecessor contract ring buffer.
spbpf.program @dns_emit "xdp" {
^bb0(%ctx: !spbpf.ctx<"xdp">):
  %r = spbpf.ringbuf.reserve "<unit>_dns_events" : !spbpf.maybe_reservation<!spbpf.record<"dns_event", 128>>
  spbpf.ringbuf.if_reserved %r : !spbpf.maybe_reservation<!spbpf.record<"dns_event", 128>> present {
  ^present(%res: !spbpf.reservation<!spbpf.record<"dns_event", 128>>):
    spbpf.ringbuf.submit %res : !spbpf.reservation<!spbpf.record<"dns_event", 128>>
    spbpf.yield
  } absent {
    spbpf.yield
  }
  spbpf.verdict "pass"
}
