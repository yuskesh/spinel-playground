package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E126 の試験: socket_filter (P026 段 ②)。

func sfData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "sf", name)
}

// TestSfBuildNoRoot は E126 の root なしの部分: sfio と sfattach (C の helper の socketpair を持つ) が build と link を通る。
func TestSfBuildNoRoot(t *testing.T) {
	parallel(t)
	cfg := lpmConfig(t)
	for _, n := range []string{"sfio", "sfattach"} {
		buildDataProgram(t, sfData(n+".rb"), cfg)
	}
}

// TestSfUserAPI は E126 H4 (root): load の unmet 0、attach_socket と test_run_skb_packet の誤りの class (手で書いた期待 sfio.want)。
func TestSfUserAPI(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, sfData("sfio.rb"), lpmConfig(t))
	want, _ := os.ReadFile(sfData("sfio.want"))
	if out := feed(t, true, "", exe); out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestSfAttach は E126 H6 (root、自分の socket だけ): 自分の socketpair の受け手に付けた filter が 64 以下の datagram だけを通す (手で書いた期待 sfattach.want)。
func TestSfAttach(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, sfData("sfattach.rb"), lpmConfig(t))
	want, _ := os.ReadFile(sfData("sfattach.want"))
	if out := feed(t, true, "", exe); out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// tSfScript は t_sf の表 (期待の値を持たない — 双子と kernel を比べる): frame の長さの境界と固定の seed の乱数 64。各行は run と dump。
func tSfScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(n int) { fmt.Fprintf(&b, "run short_only %s\ndump\n", strings.Repeat("00", n)) }
	row("s_bounds") // len 0 (14 byte)・1・46・64 (keep の最後)・65 (drop の最初)・86・1500
	for _, n := range []int{14, 15, 60, 78, 79, 100, 1514} {
		run(n)
	}
	row("s_random")
	r := rand.New(rand.NewSource(126))
	for i := 0; i < 64; i++ {
		run(14 + r.Intn(1501))
	}
	return b.String()
}

// TestSfTable は E126 H5 (host 7.1.8、root、test run だけ): t_sf の表で双子と kernel の出力が行ごとに一致、kernel の出力に keep の ret=-1 と drop の ret=0 が
// 境界の行に在る。
func TestSfTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, sfData("t_sf.rb"))
	script := tSfScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## s_bounds\n", "ret=-1\n", "Out[0]=0\n", "ret=-1\n", "Out[0]=64\n", "ret=0\n", "Out[0]=65\n", "## s_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestSfTableOut は E126 の成果物: 表の手順と kernel・双子の出力を E126_OUT に残す。
func TestSfTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E126_OUT")
	if o == "" {
		t.Skip("E126_OUT")
	}
	h := buildHarnesses(t, sfData("t_sf.rb"))
	script := tSfScript()
	os.WriteFile(filepath.Join(o, "t_sf.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_sf.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_sf.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
