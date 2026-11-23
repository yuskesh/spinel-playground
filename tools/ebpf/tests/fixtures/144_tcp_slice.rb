# E054/E416: `xdp__tcp_slice__<name>` -- the pure-XDP TCP slice (the BUNDLE form).
#
# The body is a MARKER. The codegen recognises the name and replaces the whole
# method with the generated state machine (bpf_conntab + counters + csum/swap/
# build helpers + spnl_tcp_slice_main), leaving only a thin SEC("xdp") entry.
# Whatever is written below is discarded.
#
# This file was E407's NEGATIVE fixture (144_tcp_slice_withdrawn) between E407
# and E416: the same source, refused. Reusing it rather than adding a new number
# means this golden can be diffed straight against the retired oracle's own
# output for the same input (results/E054/generated_tcp_slice.bpf.c).
def xdp__tcp_slice__health
  XDP_PASS
end
