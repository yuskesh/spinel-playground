package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E123 の試験: XDP の adjust_tail — 縮める側だけ (P026 段 ② — F13)。

func adjtData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "adjt", name)
}

// tAdjtScript は t_adjt の表 (期待の値を持たない — 双子と kernel を比べる): 3 つの program × frame の長さ (境界 −4 は 18 / 17、−46 は 60 / 59)、
// 固定の seed の乱数 32。frame は E122 の adjhFrame (先頭の 16 byte が 1, 2, …)。
func tAdjtScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(n int) {
		for _, p := range []string{"t0", "t4", "t46"} {
			fmt.Fprintf(&b, "run %s %s\ndump\n", p, adjhFrame(n))
		}
	}
	row("t_bounds")
	for _, n := range []int{14, 17, 18, 22, 59, 60, 64, 1514} {
		run(n)
	}
	row("t_random")
	r := rand.New(rand.NewSource(123))
	for i := 0; i < 32; i++ {
		run(14 + r.Intn(1501))
	}
	return b.String()
}

// TestAdjtTable は E123 H4 (host 7.1.8、root、test run だけ): t_adjt の表で双子と kernel の出力が行ごとに一致、kernel の出力に失敗の −22 と成功の 0 が
// 境界の行に在る。
func TestAdjtTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, adjtData("t_adjt.rb"))
	script := tAdjtScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## t_bounds\n", "Out[1]=-22\n", "Out[1]=0\n", "Out[2]=-22\n", "Out[2]=0\n", "## t_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestAdjtTableOut は E123 の成果物: 表の手順と kernel・双子の出力を E123_OUT に残す。
func TestAdjtTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E123_OUT")
	if o == "" {
		t.Skip("E123_OUT")
	}
	h := buildHarnesses(t, adjtData("t_adjt.rb"))
	script := tAdjtScript()
	os.WriteFile(filepath.Join(o, "t_adjt.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_adjt.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_adjt.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
