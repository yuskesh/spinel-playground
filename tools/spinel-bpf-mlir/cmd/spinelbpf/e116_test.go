package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E116 の試験 (P026 — kprobe の pointer の引数の先の固定幅の読み): 生成物 (H1)・双子の smoke (H3)・実の attach の 2 段の差動と濾しの対照
// (H4 — root、load が通ることが H5)。負の例 (H2) は internal/frontend の testdata/neg の kr_*.rb (TestNegative)。

func kreadSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kread.rb")
}

// kreadCalls は H3 / H4 の openat2 (mode・resolve・回数)。mode 0x45116000 は数え、420 (0o644 — 他の open の形) は除く。
var kreadCalls = [][3]int64{{1158766592, 5, 2}, {1158766592, 9, 1}, {420, 1, 1}}

var kreadWant = []string{"Out[0]=3", "Out[1]=9", "Out[2]=0", "Out[3]=-34", "Out[4]=0"}

// TestKreadArtefacts は H1: .mlir の kprobe.arg の直後の read_scalar、schema の ptr の params、ELF の requirements の版 5 と kprobearg ptr・helper 113。
func TestKreadArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(kreadSrc())
	src := filepath.Join(d, "trace_kread.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kread.mlir"))
	for _, w := range []string{"offset 8 : i64 -> i64, i64", "offset 16 : i64 -> i64, i64", "offset 0 : i64 -> i8, i64", "arith.extui"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	lines := strings.Split(string(m), "\n")
	for i, l := range lines { // read_scalar の addr は直前の kprobe.arg の結果 (bpf-mlir E529 の直の producer)
		if strings.Contains(l, "ebpf.kernel.read_scalar") && (i == 0 || !strings.Contains(lines[i-1], "ebpf.kprobe.arg %ctx")) {
			t.Errorf("read_scalar at line %d does not follow its kprobe.arg:\n%s\n%s", i+1, lines[i-1], l)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_kread.schema.json"))
	if strings.Count(string(s), `"kind": "ptr"`) != 2 {
		t.Errorf("schema: want two ptr params:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kread.bpf.o"))
	for _, w := range []string{"ebpf-requirements 5\n", "helper\ton_open\tprobe_read_kernel\t113\n", "attach\ton_open\tkprobe\tdo_sys_openat2\narch\ton_open\tx86_64\nctxfield\ton_open\tpt_regs\tsi\t104\t8\nctxfield\ton_open\tpt_regs\tdx\t96\t8\nkprobearg\ton_open\t2\tptr\nkprobearg\ton_open\t3\tptr\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// kreadTwinRuns は双子の run の列 (openat2 の回数だけ — mode と resolve の読みは成功 (status 0)、filename の読みは失敗 −34 の値 0)。
func kreadTwinRuns(b *strings.Builder) {
	for _, c := range kreadCalls {
		for i := int64(0); i < c[2]; i++ {
			fmt.Fprintf(b, "run on_open r3_8=%d r3_16=%d r2_0=0 s2_0=-34\n", c[0], c[1])
		}
	}
}

// TestKreadTwinSmoke は H3: 双子の 4 回の run → Out[0]=3・Out[1]=9・Out[2]=0・Out[3]=−34・Out[4]=0。
func TestKreadTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kread")
	var in strings.Builder
	in.WriteString("reset\npoke Filter 0 4242\ntask 18219251273881\n") // tgid 4242 << 32 | tid 4249
	kreadTwinRuns(&in)
	in.WriteString("dump\n")
	wantLines(t, feed(t, false, in.String(), tw), kreadWant...)
}

// kreadAttachDiff は H4 (と H6) の 2 段の差動: kernel は do_sys_openat2 の kprobe に向けて harness の thread が openat2 を
// (Filter は self なら own の tgid、でなければ tgid 1)、双子は同じ tid の task で同じ読みの値と status を。
func kreadAttachDiff(t *testing.T, h harnessSet, self bool) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n")
	for _, c := range kreadCalls {
		fmt.Fprintf(&ks, "openat2 %d %d %d\n", c[0], c[1], c[2])
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, _ := traceKernel(t, kernel)
	var tid int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tid=%d", &tid)
	}
	if tid == 0 {
		t.Fatalf("no tid from the openat2 command:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	fmt.Fprintf(&ts, "task %d\n", tgid<<32|tid)
	kreadTwinRuns(&ts)
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestKreadAttachDifferential は H4 と H5 (root): load が通り (do_sys_openat2 の kprobearg ptr の照合)、own の tgid と mode で絞った kernel の dump が
// ちょうど Out[0]=3・Out[1]=9・Out[2]=0・Out[3]=−34・Out[4]=0 で双子と一致、Filter を tgid 1 にすると kernel も双子も全て 0。
func TestKreadAttachDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kreadSrc())
	k, w := kreadAttachDiff(t, h, true)
	t.Log(k)
	sameDump(t, "kread attach", k, w)
	wantLines(t, k, kreadWant...)
	k, w = kreadAttachDiff(t, h, false)
	t.Log(k)
	sameDump(t, "kread attach filtered", k, w)
	wantLines(t, k, "Out[0]=0", "Out[1]=0", "Out[2]=0", "Out[3]=0", "Out[4]=0")
}
