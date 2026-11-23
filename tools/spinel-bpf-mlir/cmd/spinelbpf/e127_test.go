package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E127 の試験: cgroup_skb (P026 段 ②)。

func cgData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "cg", name)
}

// e127Cgroup は実の attach の試験が作り消す子の cgroup (E127 追補 1 — 固定の名前)。
const e127Cgroup = "/sys/fs/cgroup/spinelbpf-e127"

// e127Out は E127_OUT が在ればその下の file に s を書く (観測を results に — E126 の完了のレビューの注)。
func e127Out(t *testing.T, name, s string) {
	if o := os.Getenv("E127_OUT"); o != "" {
		if err := os.WriteFile(filepath.Join(o, name), []byte(s), 0o644); err != nil {
			t.Errorf("writing %s: %v", name, err)
		}
	}
}

// TestCgBuildNoRoot は E127 の root なしの部分: cgio と cgattach (C の helper の cgroup と UDP を持つ) が build と link を通る。
func TestCgBuildNoRoot(t *testing.T) {
	parallel(t)
	cfg := lpmConfig(t)
	for _, n := range []string{"cgio", "cgattach"} {
		buildDataProgram(t, cgData(n+".rb"), cfg)
	}
}

// TestCgUserAPI は E127 H4 (root): load の unmet 0、attach_cgroup と test_run_skb_packet の誤りの class と判定 (手で書いた期待 cgio.want)。
func TestCgUserAPI(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, cgData("cgio.rb"), lpmConfig(t))
	want, _ := os.ReadFile(cgData("cgio.want"))
	out := feed(t, true, "", exe)
	t.Logf("cgio:\n%s", out)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// cgAttach は cgattach を root で走らせ、走らせる前と後に子の cgroup が無いことを確かめる (E127 追補 1)。失敗の時も t.Cleanup が残った dir を消す。
func cgAttach(t *testing.T, exe string) (out, cg string) {
	t.Helper()
	if m, _ := filepath.Glob(e127Cgroup + "*"); len(m) != 0 {
		t.Fatalf("before the run: %v exists — remove it first (E127)", m)
	}
	t.Cleanup(func() {
		if _, err := os.Stat(e127Cgroup); err == nil {
			if o, err := sudoCmd(t, "rmdir", e127Cgroup).CombinedOutput(); err != nil {
				t.Errorf("cleanup: rmdir %s: %v %s", e127Cgroup, err, o)
			}
		}
	})
	out = feed(t, true, "", exe)
	after := "none"
	if m, _ := filepath.Glob(e127Cgroup + "*"); len(m) != 0 {
		after = strings.Join(m, " ")
		t.Errorf("after the run: %s exists", after)
	}
	return out, "before: none\nafter: " + after + "\n"
}

// TestCgAttach は E127 H6 (root、子の cgroup と 127.0.0.1 の自分の UDP だけ): ingress は payload 1〜36 だけを受け、egress は 37〜200 が EPERM、
// 子の cgroup は終わりに無い (手で書いた期待 cgattach.want)。観測は E127_OUT の cgattach.out と cgattach_cgroup.txt に。
func TestCgAttach(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, cgData("cgattach.rb"), lpmConfig(t))
	out, cg := cgAttach(t, exe)
	t.Logf("cgattach:\n%s%s", out, cg)
	e127Out(t, "cgattach.out", out)
	e127Out(t, "cgattach_cgroup.txt", cg)
	want, _ := os.ReadFile(cgData("cgattach.want"))
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// cgFrame は n byte の frame (eth の 14 byte の後が IPv4 の header) で、protocol の byte (offset 14 + 9) が proto。
func cgFrame(n, proto int) string {
	b := make([]byte, n)
	if n > 23 {
		b[23] = byte(proto)
	}
	return fmt.Sprintf("%x", b)
}

// tCgScript は t_cg の表 (期待の値を持たない — 双子と kernel を比べる): frame の長さの境界と protocol の byte を ingress と egress の program で、固定の seed の乱数 64。
func tCgScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(n, proto int) {
		for _, p := range []string{"small_in", "small_out"} {
			fmt.Fprintf(&b, "run %s %s\ndump\n", p, cgFrame(n, proto))
		}
	}
	row("c_bounds") // len 0 (window の外)・19 (20 byte の window の外)・20 (中)・64 (allow の最後)・65 (deny の最初)・1500
	for _, n := range []int{14, 33, 34, 78, 79, 1514} {
		run(n, 17)
	}
	row("c_proto")
	for _, p := range []int{6, 17, 255} {
		run(60, p)
	}
	row("c_random")
	r := rand.New(rand.NewSource(127))
	for i := 0; i < 64; i++ {
		run(14+r.Intn(1501), r.Intn(256))
	}
	return b.String()
}

// TestCgTable は E127 H5 (host 7.1.8、root、test run だけ): t_cg の表で双子と kernel の出力が行ごとに一致、kernel の出力に allow の ret=1 と deny の ret=0 が境界の行に在る。
func TestCgTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, cgData("t_cg.rb"))
	script := tCgScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## c_bounds\n", "ret=1\n", "Out[0]=0\n", "ret=1\n", "Out[0]=64\n", "ret=0\n", "Out[0]=65\n", "## c_proto\n", "Out[1]=6\n", "Out[1]=255\n", "## c_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestCgTableOut は E127 の成果物: 表の手順と kernel・双子の出力を E127_OUT に残す。
func TestCgTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E127_OUT")
	if o == "" {
		t.Skip("E127_OUT")
	}
	h := buildHarnesses(t, cgData("t_cg.rb"))
	script := tCgScript()
	os.WriteFile(filepath.Join(o, "t_cg.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_cg.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_cg.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
