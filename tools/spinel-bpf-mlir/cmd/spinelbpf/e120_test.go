package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E120 の試験: xdp / tc の context の field (P026 段 ②)。

func ctxfData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "ctxf", name)
}

// TestCtxfBuildNoRoot は E120 の root なしの部分: ctxfattach (C の helper の netns と UDP を持つ) が build と link を通る。
func TestCtxfBuildNoRoot(t *testing.T) {
	parallel(t)
	buildDataProgram(t, ctxfData("ctxfattach.rb"), lpmConfig(t))
}

// ctxfAttach は ctxfattach を root で走らせ、1 行目 (netns の inode の前と後 — 違うときだけ attach、E128 と同じ) を確かめて残りを返す。
func ctxfAttach(t *testing.T, exe string) (netns, rest string) {
	t.Helper()
	out := feed(t, true, "", exe)
	loc := nfNetnsLine.FindStringIndex(out)
	if loc == nil {
		t.Fatalf("the first line is not a moved netns:\n%s", out)
	}
	return out[:loc[1]], out[loc[1]:]
}

// TestCtxfAttach は E120 H5 (root、自分の netns の lo だけ): xdp の ingress_ifindex は 1、egress で書いた mark 42 が lo の ingress に届き +7 で 49
// (手で書いた期待 ctxfattach.want — netns の行は moved=1 だけを見る)。観測は E120_OUT の ctxfattach.out に。
func TestCtxfAttach(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, ctxfData("ctxfattach.rb"), lpmConfig(t))
	netns, rest := ctxfAttach(t, exe)
	t.Logf("ctxfattach:\n%s%s", netns, rest)
	if o := os.Getenv("E120_OUT"); o != "" {
		os.WriteFile(filepath.Join(o, "ctxfattach.out"), []byte(netns+rest), 0o644)
	}
	want, _ := os.ReadFile(ctxfData("ctxfattach.want"))
	if rest != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", rest, want)
	}
}

// tCtxfScript は t_ctxf の表 (期待の値を持たない — 双子と kernel を比べる): 3 つの program を frame の長さ 14・60・100・1514 と固定の seed の乱数 32 で。
func tCtxfScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(n int) {
		for _, p := range []string{"ifx", "mark_out", "mark_in"} {
			fmt.Fprintf(&b, "run %s %s\ndump\n", p, strings.Repeat("00", n))
		}
	}
	row("f_bounds")
	for _, n := range []int{14, 60, 100, 1514} {
		run(n)
	}
	row("f_random")
	r := rand.New(rand.NewSource(120))
	for i := 0; i < 32; i++ {
		run(14 + r.Intn(1501))
	}
	return b.String()
}

// TestCtxfTable は E120 H4 (host 7.1.8、root、test run だけ): t_ctxf の表で双子と kernel の出力が行ごとに一致、kernel の出力に ifindex 1・len・mark の
// 0 と 7 が意図した行に在る。
func TestCtxfTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, ctxfData("t_ctxf.rb"))
	script := tCtxfScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## f_bounds\n", "Out[0]=1\n", "Out[1]=14\n", "Out[2]=0\n", "Out[3]=7\n", "Out[1]=1514\n", "## f_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestCtxfTableOut は E120 の成果物: 表の手順と kernel・双子の出力を E120_OUT に残す。
func TestCtxfTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E120_OUT")
	if o == "" {
		t.Skip("E120_OUT")
	}
	h := buildHarnesses(t, ctxfData("t_ctxf.rb"))
	script := tCtxfScript()
	os.WriteFile(filepath.Join(o, "t_ctxf.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_ctxf.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_ctxf.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
