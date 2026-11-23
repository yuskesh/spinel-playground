package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E122 の試験: XDP の adjust_head (P026 段 ② — F12)。

func adjhData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "adjh", name)
}

// adjhFrame は n byte の frame の 16 進 — 先頭の 16 byte は 1, 2, 3, … (動いた先頭の byte が見える)、残りは 0。
func adjhFrame(n int) string {
	b := make([]byte, n)
	for i := 0; i < n && i < 16; i++ {
		b[i] = byte(i + 1)
	}
	return fmt.Sprintf("%x", b)
}

// tAdjhScript は t_adjh の表 (期待の値を持たない — 双子と kernel を比べる): frame の長さ × delta (D[0] に poke)、固定の seed の乱数 64。
func tAdjhScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(n, d int) { fmt.Fprintf(&b, "poke D 0 %d\nrun shift %s\ndump\n", d, adjhFrame(n)) }
	row("a_bounds") // 伸ばす側は −100 (成功) と −1000 (失敗) だけ、縮める側は残り 14 (成功) と 13 (失敗)
	for _, n := range []int{14, 15, 60, 1514} {
		for _, d := range []int{-1000, -100, -4, 0, 4, 14, n - 14, n - 13} {
			run(n, d)
		}
	}
	row("a_random")
	r := rand.New(rand.NewSource(122))
	for i := 0; i < 64; i++ {
		n := 14 + r.Intn(1501)
		run(n, r.Intn(n+101)-100)
	}
	return b.String()
}

// TestAdjhTable は E122 H4 (host 7.1.8、root、test run だけ): t_adjh の表で双子と kernel の出力が行ごとに一致、kernel の出力に失敗の −22 と成功の 0、
// 伸ばした先頭の 0 と縮めた後の元の byte が意図した行に在る。
func TestAdjhTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, adjhData("t_adjh.rb"))
	script := tAdjhScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## a_bounds\n", "Out[0]=-22\n", "Out[0]=0\nOut[1]=0\n", "Out[0]=0\nOut[1]=5\n", "## a_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestAdjhTableOut は E122 の成果物: 表の手順と kernel・双子の出力を E122_OUT に残す。
func TestAdjhTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E122_OUT")
	if o == "" {
		t.Skip("E122_OUT")
	}
	h := buildHarnesses(t, adjhData("t_adjh.rb"))
	script := tAdjhScript()
	os.WriteFile(filepath.Join(o, "t_adjh.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_adjh.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_adjh.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
