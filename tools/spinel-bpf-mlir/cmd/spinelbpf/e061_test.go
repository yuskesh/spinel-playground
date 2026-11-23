package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E061 の試験: 例 tlvwalk (loop の本体の packet の窓 — P015) の生成物・selftest・双子と kernel の 4 packet の smoke。

var tlvwalkArtefacts = []string{"tlvwalk.mlir", "tlvwalk.schema.json", "tlvwalk.maps.json", "tlvwalk.domain.json", "tlvwalk.bpf.o",
	"tlvwalk.compile_warnings.txt", "tlvwalk_embed.S", "tlvwalk_embed.o"}

// TestTlvwalkArtefacts は E061 の H6: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestTlvwalkArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "tlvwalk", "tlvwalk.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "tlvwalk.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range tlvwalkArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "tlvwalk", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestTlvwalkSelftestHost は E061 の H4 (root): 4 つの packet で Types 0 1 1 1 8 1 0 0・walked 12・capped 1。
func TestTlvwalkSelftestHost(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "tlvwalk", "tlvwalk.rb"))
	src := filepath.Join(d, "tlvwalk.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "tlvwalk")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "types=0,1,1,1,8,1,0,0 walked=12 capped=1\nselftest ok") {
		t.Errorf("selftest failed")
	}
}

// tlvPacket は selftest と同じ packet の 16 進 (Ethernet の 14 byte の 0 + tlvs、長さ n に 0 で満たす)。
func tlvPacket(tlvs []int, n int) string {
	f := make([]int, 14, n)
	f = append(f, tlvs...)
	for len(f) < n {
		f = append(f, 0)
	}
	var s strings.Builder
	for _, x := range f {
		fmt.Fprintf(&s, "%02x", x)
	}
	return s.String()
}

// TestTlvwalkHarnessSmoke は E061 の H5 (root): 同じ 4 つの packet の harness の手順で双子と kernel の dump が一致 (表と変異は E062)。
func TestTlvwalkHarnessSmoke(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, filepath.Join(repoRoot(), "examples", "tlvwalk", "tlvwalk.rb"))
	script := "reset\n"
	for _, p := range []string{
		tlvPacket([]int{1, 2, 9, 9, 2, 0, 3, 1, 7, 0}, 64),
		tlvPacket([]int{4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0, 4, 0}, 64),
		tlvPacket([]int{5, 60, 1, 2, 3}, 30),
		tlvPacket(nil, 14),
	} {
		script += "run tlv " + p + "\n"
	}
	script += "dump\n"
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	t.Logf("twin:\n%s", tw)
	if tw != kn {
		t.Fatalf("twin and kernel differ:\n--- twin\n%s--- kernel\n%s", tw, kn)
	}
	if !strings.Contains(tw, "Types[4]=8") || !strings.Contains(tw, "Walks[0]=12") {
		t.Errorf("unexpected dump")
	}
}
