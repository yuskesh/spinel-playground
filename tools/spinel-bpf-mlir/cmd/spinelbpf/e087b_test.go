package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// E087 部 2 の試験 (P021): tp_btf の attach と fork の trigger の差動 (bml の pin 6bf8bc0・bpf-mlir v1.1.0)。

// TestTpBtfForkDifferential は E087 の H5 (host、root): kernel の harness が attach_tp_btf の後に自分の tgid を Cfg に書き N 回 fork し、Out (数・
// 最後の子の pid・tgid) が試験の知る値と、双子に同じ値を与えた run の Out と一致する。自分でない fork は数えない (他の process の fork が在っても数は N)。
func TestTpBtfForkDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, tFork())
	const n = 5
	script := "reset\nself\npokeself Cfg 0\n" + strings.Repeat("fork\n", n) + "dump\n"
	kn := feed(t, true, script, h.kernelBin)
	var tgid string
	var children []string
	for _, l := range strings.Split(kn, "\n") {
		switch {
		case strings.HasPrefix(l, "tgid="):
			tgid = strings.TrimPrefix(l, "tgid=")
		case strings.HasPrefix(l, "child="):
			children = append(children, strings.TrimPrefix(l, "child="))
		}
	}
	if tgid == "" || len(children) != n {
		t.Fatalf("kernel harness output:\n%s", kn)
	}
	// 双子: 同じ Cfg (poke は双子の側で) と n 回の run (親の tgid・子の pid と tgid)
	var ts strings.Builder
	ts.WriteString("reset\npoke Cfg 0 " + tgid + "\n")
	for _, c := range children {
		ts.WriteString("run on_fork a0.tgid=" + tgid + " a1.pid=" + c + " a1.tgid=" + c + "\n")
	}
	ts.WriteString("dump\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	last := children[n-1]
	want := []string{"Out[0]=" + strconv.Itoa(n), "Out[1]=" + last, "Out[2]=" + last}
	for _, w := range want {
		if !strings.Contains(kn, w+"\n") {
			t.Errorf("kernel: want %q in\n%s", w, kn)
		}
		if !strings.Contains(tw, w+"\n") {
			t.Errorf("twin: want %q in\n%s", w, tw)
		}
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}

var forkcountArtefacts = []string{"forkcount.mlir", "forkcount.schema.json", "forkcount.maps.json", "forkcount.domain.json", "forkcount.bpf.o",
	"forkcount.compile_warnings.txt", "forkcount_embed.S", "forkcount_embed.o"}

// TestForkcountArtefacts は E087 の H6: 2 回の build の生成物が commit 済みの物と byte 同じ。
func TestForkcountArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "forkcount", "forkcount.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "forkcount.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range forkcountArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "forkcount", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
}

// TestForkcountSelftestHost は E087 の H6 (host): root と uid 1000 の CAP_BPF + CAP_PERFMON の selftest (自分の fork を 5 回 — 数と最後の子の pid)。
func TestForkcountSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "forkcount", "forkcount.rb"))
	src := filepath.Join(d, "forkcount.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "forkcount")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	if !strings.Contains(out, "forks=5 ") || !strings.Contains(out, "selftest ok\n") {
		t.Errorf("root selftest:\n%s", out)
	}
	nr, err := nonroot(t, "+bpf,+perfmon", "", exe, "--selftest")
	if err != nil || !strings.Contains(nr, "forks=5 ") || !strings.Contains(nr, "selftest ok\n") {
		t.Errorf("non-root +bpf,+perfmon selftest (err %v):\n%s", err, nr)
	}
	t.Logf("root:\n%s\nnon-root:\n%s", out, nr)
}
