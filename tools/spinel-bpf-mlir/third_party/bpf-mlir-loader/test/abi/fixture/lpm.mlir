// E016 の fixture: lpm_trie の pol (値 u32・max 3 — 満杯の ENOSPC の試験) と pol8 (値 u64・max 16)。key の record は mojo の library の名前
// mojobpf_lpm_key4 (prefixlen u32・addr [4]u8 — mojo の Go の loader との差動のため)。xp は両方を 10.0.0.1/32 で引く (map を参照するだけ)
ebpf.program @xp "xdp" maps [@pol, @pol8] {
^bb0(%ctx: !ebpf.ctx<"xdp">, %pol: !ebpf.map<"lpm_trie", !ebpf.record<"mojobpf_lpm_key4", 8>, i32>, %pol8: !ebpf.map<"lpm_trie", !ebpf.record<"mojobpf_lpm_key4", 8>, i64>):
  %plen = arith.constant 32 : i32
  %a0 = arith.constant 10 : i8
  %a1 = arith.constant 0 : i8
  %a3 = arith.constant 1 : i8
  %k = ebpf.record.make ["prefixlen", "addr[0]", "addr[1]", "addr[2]", "addr[3]"] (%plen, %a0, %a1, %a1, %a3) : (i32, i8, i8, i8, i8) -> !ebpf.record<"mojobpf_lpm_key4", 8>
  %m = ebpf.map.lookup %pol[%k] : !ebpf.map<"lpm_trie", !ebpf.record<"mojobpf_lpm_key4", 8>, i32>, !ebpf.record<"mojobpf_lpm_key4", 8> -> !ebpf.maybe_ref<i32>
  ebpf.ref.check %m : !ebpf.maybe_ref<i32> present {
  ^p(%r: !ebpf.borrowed<i32>):
    ebpf.yield
  } absent {
    ebpf.yield
  }
  %m8 = ebpf.map.lookup %pol8[%k] : !ebpf.map<"lpm_trie", !ebpf.record<"mojobpf_lpm_key4", 8>, i64>, !ebpf.record<"mojobpf_lpm_key4", 8> -> !ebpf.maybe_ref<i64>
  ebpf.ref.check %m8 : !ebpf.maybe_ref<i64> present {
  ^p(%r: !ebpf.borrowed<i64>):
    ebpf.yield
  } absent {
    ebpf.yield
  }
  ebpf.verdict "pass"
}
