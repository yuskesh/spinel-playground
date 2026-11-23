package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRecordHostLoad は E020 の H3 (root): record の正の例の ELF が host の照合付きの load (段 2' の bindrt の records の照合を含む) を通る。
// 利用者の側は load だけ (record の map_get / map_put は E021)。
func TestRecordHostLoad(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"rec_basic", "rec_pkt", "ring_basic"} { // ring_basic は E026 (ring buffer の maps.json の行と records)
		b, err := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e020-")
		if err != nil {
			t.Fatal(err)
		}
		src := filepath.Join(d, name+".rb")
		os.WriteFile(src, append(b, []byte("\nrequire \"spinelbpf\"\nobj = SpinelBPF.load_embedded\nputs \"loaded unmet=#{obj.unmet.length}\"\nobj.close\n")...), 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		exe := filepath.Join(d, name)
		if err := Link(cfg, src, exe); err != nil {
			t.Fatal(err)
		}
		out := feed(t, true, "", exe)
		if !strings.Contains(out, "loaded unmet=0") {
			t.Fatalf("%s: %s", name, out)
		}
		t.Logf("%s: %s", name, strings.TrimSpace(out))
	}
}
