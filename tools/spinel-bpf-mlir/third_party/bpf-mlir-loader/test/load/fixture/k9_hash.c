// E009 の K9 の確かめ (レビュー役の補足): max_entries 4294967295 の BPF_F_NO_PREALLOC の hash — map の定義の BTF の ARRAY (int × N) が
// U32_MAX を超え kernel が BTF を拒む (bpf-mlir E323)。確保しない map なので 6.x でも map の作成の ENOMEM より先に BTF の拒否が見える。
// bpf-mlir v0.17.0 の ebpf-compile はこの定義を K9 で止めるので clang の C で作る (照合の requirements を持たない — load_case --unchecked で guard だけ)。
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(map_flags, BPF_F_NO_PREALLOC);
	__uint(max_entries, 4294967295u);
	__type(key, __u32);
	__type(value, __u32);
} big SEC(".maps");

SEC("xdp")
int prog(struct xdp_md *ctx)
{
	__u32 k = 0, *v = bpf_map_lookup_elem(&big, &k);
	return v ? XDP_DROP : XDP_PASS;
}

char _license[] SEC("license") = "GPL";

// guard (load_case --unchecked) は requirements を読むので、bpf-mlir と同じ形の section を NUL 無しで置く (schema の sha は照合しないので 0)
asm(".section .ebpf_requirements,\"\",@progbits\n"
    ".ascii \"ebpf-requirements 5\\n\"\n"
    ".ascii \"schema\\tsha256\\t0000000000000000000000000000000000000000000000000000000000000000\\n\"\n"
    ".ascii \"program\\tprog\\txdp\\t6\\n\"\n"
    ".ascii \"helper\\tprog\\tmap_lookup_elem\\t1\\n\"\n"
    ".ascii \"map\\tbig\\thash\\t1\\tu32\\tu32\\t4294967295\\t1\\n\"\n"
    ".ascii \"btf\\tarray\\nbtf\\tdatasec\\nbtf\\tfunc\\nbtf\\tfunc_global\\nbtf\\tfunc_proto\\nbtf\\tint\\nbtf\\tptr\\nbtf\\tstruct\\nbtf\\tvar\\n\"\n"
    ".previous\n");
