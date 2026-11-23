package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// TestFlowKeysOrder は E130 追補 1 (H7 — root なし): library の SpinelBPF::FLOW_KEYS の名前の順と、test_run_flow_dissector の Array を作る inline の C
// (spinelbpf_flow_key の off / wid の表) の順と、bpf-mlir の UAPI の表 (KernelABITable.inc の bpf_flow_keys の offset と幅) を照らす。順を変えると利用者の
// program が黙って違う field を読むので、食い違えば名指しで落ちる。
func TestFlowKeysOrder(t *testing.T) {
	parallel(t)
	lib, err := os.ReadFile(filepath.Join(repoRoot(), "ruby", "lib", "spinelbpf.rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(lib)
	m := regexp.MustCompile(`(?s)FLOW_KEYS = \[(.*?")\]\n`).FindStringSubmatch(src)
	if m == nil {
		t.Fatal("SpinelBPF::FLOW_KEYS is not in ruby/lib/spinelbpf.rb")
	}
	var names []string
	for _, q := range regexp.MustCompile(`"([a-z0-9_\[\]]+)"`).FindAllStringSubmatch(m[1], -1) {
		names = append(names, q[1])
	}
	nums := func(name string) []int {
		r := regexp.MustCompile(`static const int ` + name + `\[20\] = \{([0-9, ]+)\};`).FindStringSubmatch(src)
		if r == nil {
			t.Fatalf("the inline C table %s is not in ruby/lib/spinelbpf.rb", name)
		}
		var out []int
		for _, s := range strings.Split(r[1], ",") {
			v, _ := strconv.Atoi(strings.TrimSpace(s))
			out = append(out, v)
		}
		return out
	}
	off, wid := nums("off"), nums("wid")
	tbl, err := os.ReadFile(filepath.Join(repoRoot(), "third_party", "bpf-mlir", "lib", "Dialect", "BPFABI", "KernelABITable.inc"))
	if err != nil {
		t.Fatal(err)
	}
	type fld struct{ off, wid, count int }
	uapi := map[string]fld{}
	for _, r := range regexp.MustCompile(`BPFABI_STRUCT_FIELD\("bpf_flow_keys", "([a-z0-9_]+)", ([0-9]+), ([0-9]+), ([0-9]+), "int"\)`).FindAllStringSubmatch(string(tbl), -1) {
		o, _ := strconv.Atoi(r[2])
		w, _ := strconv.Atoi(r[3])
		c, _ := strconv.Atoi(r[4])
		uapi[r[1]] = fld{o, w, c}
	}
	if len(names) != 20 || len(off) != 20 || len(wid) != 20 {
		t.Fatalf("FLOW_KEYS %d names, off %d, wid %d — want 20 each", len(names), len(off), len(wid))
	}
	idx := regexp.MustCompile(`^([a-z0-9_]+)\[([0-3])\]$`)
	for i, n := range names {
		base, k := n, 0
		if s := idx.FindStringSubmatch(n); s != nil {
			base = s[1]
			k, _ = strconv.Atoi(s[2])
		}
		f, ok := uapi[base]
		if !ok {
			t.Errorf("FLOW_KEYS[%d] %q is not a field of bpf_flow_keys in the UAPI table", i, n)
			continue
		}
		if want := f.off + k*f.wid; off[i] != want || wid[i] != f.wid {
			t.Errorf("FLOW_KEYS[%d] %q: the inline C reads offset %d width %d, the UAPI table says %d / %d", i, n, off[i], wid[i], want, f.wid)
		}
	}
}
