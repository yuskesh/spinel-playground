module attributes {spinel_facts.version = 1 : i64, spinel_facts.producer = "handwritten", spinel_facts.producer_revision = "E001", spinel_facts.profile = "handwritten-v1", spinel_facts.status = "success", spinel_facts.integer_bits = 64 : i64, spinel_facts.overflow = "raise", spinel_facts.refusal_checked = true, spinel_facts.refusal_count = 0 : i64} {
  "spinel_facts.source"() {file_id = 0 : i64, path = "xdpcount.rb", text = "require \"bpf\"\0A\0ACounts = BPF::ArrayMap.new(\"Counts\", :u64, 2)\0A\0Adef count_pkts(ctx)\0A  Counts.atomic_add(0, 1)\0A  p = Counts.lookup(0)\0A  if p\0A    Counts.update(1, p.load)\0A  end\0A  BPF::XDP_PASS\0Aend\0ABPF.xdp :count_pkts\0A\0A"} : () -> ()
  "spinel_facts.table"() ({
    "spinel_facts.node"() {id = 1 : i64, kind = "IntegerNode", strings = {}, integers = {value = "1"}, refs = {}, arrays = {}, file_id = 0 : i64, span = [6 : i64, 23 : i64, 6 : i64, 24 : i64], literal_text = "1", literal_decimal = "1", backend_decimal = "1"} : () -> () loc("xdpcount.rb":6:24)
  }) {phase = "pristine", root_id = 1 : i64} : () -> ()
  "spinel_facts.table"() ({
    "spinel_facts.node"() {id = 1 : i64, kind = "IntegerNode", strings = {}, integers = {value = "1"}, refs = {}, arrays = {}, file_id = 0 : i64, span = [6 : i64, 23 : i64, 6 : i64, 24 : i64], literal_text = "1", literal_decimal = "1", backend_decimal = "1"} : () -> () loc("xdpcount.rb":6:24)
  }) {phase = "analyzed", root_id = 1 : i64} : () -> ()
  "spinel_facts.type"() {node_id = 1 : i64, phase = "analyzed", kind = "Integer", value_type = !spinel_facts.integer} : () -> ()
}
