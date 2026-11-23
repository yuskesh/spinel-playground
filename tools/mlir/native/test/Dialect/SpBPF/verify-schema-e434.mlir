// Check bindings against the real predecessor contract in e434-converted.json, not a synthetic
// schema.
//
// RUN: not spbpf-opt --spbpf-verify-schema=schema=%S/../../Target/SpBPF/e434-converted.json %s 2>&1 \
// RUN:   | FileCheck %s

// This partial schema covers records/ring buffers without programs, so skip program-name matching
// but continue map binding checks.
//
// Its ring buffer names resemble <unit>_dns_events and are not lookup maps.
// CHECK: 'spbpf.program' op map symbol @spnl_dns_events is not declared in the schema
spbpf.program @dns_probe "xdp" maps [@spnl_dns_events] {
^bb0(%ctx: !spbpf.ctx<"xdp">, %rb: !spbpf.map<"ringbuf", i32, i64>):
  spbpf.verdict "pass"
}
