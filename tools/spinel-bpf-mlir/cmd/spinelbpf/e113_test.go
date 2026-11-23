package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E113 の試験 (P026 — raw_tp の args): 生成物 (H1)・双子の smoke (H3)・test run の 2 段の差動 (H4 — root)・sys_enter の実の attach と濾しの対照
// (H5 — root)・attach の kind の取り違えと添字の上限 (H6 — root)。負の例 (H2) は internal/frontend の testdata/neg の rawtp_*.rb (TestNegative)。

func rawtpSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_raw_tp.rb")
}

// rawtpRuns は H3 / H4 の 5 つの run (args の a<i>=<v>) と、その後の双子 / kernel の Seen の値。
var rawtpRuns = []string{"a1=110", "a1=110 a0=5", "a1=4294967406", "a1=7", "a1=1000001 a0=737894400291"}

var rawtpWant = []string{"Seen[0]=3", "Seen[1]=1000001", "Seen[2]=3454992675", "Seen[3]=171"}

// TestRawTpArtefacts は H1 (と追補 1): .mlir の program の行と ctx.field の args、schema の program、ELF の requirements の版 9 と行。
func TestRawTpArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(rawtpSrc())
	src := filepath.Join(d, "trace_raw_tp.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_raw_tp.mlir"))
	for _, w := range []string{`ebpf.program @on_sys_enter "raw_tp" attach "sys_enter" maps [`, `ebpf.ctx.field %ctx "args"[0] : !ebpf.ctx<"raw_tp"> -> i64`, `ebpf.ctx.field %ctx "args"[1] : !ebpf.ctx<"raw_tp"> -> i64`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	if strings.Contains(string(m), `arch "x86_64"`) {
		t.Errorf("a raw_tp program has no arch:\n%s", m)
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_raw_tp.schema.json"))
	if !strings.Contains(string(s), `"kind": "raw_tp"`) || !strings.Contains(string(s), `"attach_target": "sys_enter"`) || strings.Contains(string(s), `"arch"`) || strings.Contains(string(s), `"params"`) {
		t.Errorf("schema program: want kind raw_tp, attach_target and no arch / params:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_raw_tp.bpf.o"))
	for _, w := range []string{"ebpf-requirements 9\n", "program\ton_sys_enter\traw_tracepoint\t17\n", "attach\ton_sys_enter\traw_tp\trawtp:sys_enter\n", "ctxaccess\ton_sys_enter\t-\tbpf_raw_tracepoint_args\targs\tr\t8\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestRawTpTwinSmoke は H3: 双子の 5 つの run (Filter の tgid) → Seen[0]=3・Seen[1]=1000001・Seen[2]=3454992675・Seen[3]=171。
func TestRawTpTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_raw_tp")
	var in strings.Builder
	in.WriteString("reset\npoke Filter 0 4242\ntask 18219251273881\n") // tgid 4242 << 32 | tid 4249
	for _, r := range rawtpRuns {
		fmt.Fprintf(&in, "run on_sys_enter %s\n", r)
	}
	in.WriteString("dump\n")
	wantLines(t, feed(t, false, in.String(), tw), rawtpWant...)
}

// rawtpTestRunDiff は H4 の 2 段の差動: kernel は test run (呼び手の thread の文脈) を、双子は同じ tid の task で同じ args を。
func rawtpTestRunDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\npokeself Filter 0\nself\n")
	for _, r := range rawtpRuns {
		fmt.Fprintf(&ks, "run on_sys_enter %s\n", r)
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, tids := traceKernel(t, kernel)
	if len(tids) != len(rawtpRuns) {
		t.Fatalf("want %d tids (and a 0 return from each test run), got %v:\n%s", len(rawtpRuns), tids, kernel)
	}
	var ts strings.Builder
	fmt.Fprintf(&ts, "reset\npoke Filter 0 %d\n", tgid)
	for i, r := range rawtpRuns {
		fmt.Fprintf(&ts, "task %d\nrun on_sys_enter %s\n", tgid<<32|tids[i], r)
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestRawTpTestRunDifferential は H4 (root): test run の kernel の dump が H3 の値で、双子と一致。
func TestRawTpTestRunDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, rawtpSrc())
	k, w := rawtpTestRunDiff(t, h)
	t.Log(k)
	sameDump(t, "raw_tp test run", k, w)
	wantLines(t, k, rawtpWant...)
}

// rawtpAttachDiff は H5 の 2 段の差動: kernel は sys_enter に attach した program に向けて harness の thread が getppid(2) を n 回 (Filter は
// self なら own の tgid、でなければ tgid 1)、双子は同じ tid の task で `run on_sys_enter a1=110` を n 回。
func rawtpAttachDiff(t *testing.T, h harnessSet, self bool, n int) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	fmt.Fprintf(&ks, "self\ngetppid %d\ndump\n", n)
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, _ := traceKernel(t, kernel)
	var tid int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tid=%d", &tid)
	}
	if tid == 0 {
		t.Fatalf("no tid from the getppid command:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	fmt.Fprintf(&ts, "task %d\n", tgid<<32|tid)
	for i := 0; i < n; i++ {
		ts.WriteString("run on_sys_enter a1=110\n")
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestRawTpAttachDifferential は H5 (root): sys_enter の実の attach — own の tgid で getppid を 5 回 → kernel の Seen[0] がちょうど 5
// (他の process の getppid は tgid で、自分の他の syscall は番号で除く)・Seen[1〜3] は 0、双子と一致。Filter を tgid 1 にすると数えない。
func TestRawTpAttachDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, rawtpSrc())
	k, w := rawtpAttachDiff(t, h, true, 5)
	t.Log(k)
	sameDump(t, "raw_tp attach", k, w)
	wantLines(t, k, "Seen[0]=5", "Seen[1]=0", "Seen[2]=0", "Seen[3]=0")
	k, w = rawtpAttachDiff(t, h, false, 5)
	t.Log(k)
	sameDump(t, "raw_tp attach filtered", k, w)
	wantLines(t, k, "Seen[0]=0")
}

// TestRawTpAttachKind は H6 (a) (root): raw_tp を kprobe として・kprobe を raw_tp として attach すると誤り、正しい kind は OK。
func TestRawTpAttachKind(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "rawtp_attach_kind")
	for _, w := range []string{"raw_tp as raw_tp kind=OK", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "raw_tp as kprobe kind=SpinelBPF::") || !strings.Contains(out, "kprobe as raw_tp kind=SpinelBPF::") {
		t.Errorf("attaching across kprobe / raw_tp must fail loudly")
	}
}

// TestRawTpWideIndex は H6 (b) (root): sys_enter に args[11] — load と test run は通り (args[11] = 77 を読む)、attach は bml の誤りで止まる。
func TestRawTpWideIndex(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "rawtp_wide")
	for _, w := range []string{"load kind=OK", "test_run ret=0 seen0=77 seen1=1"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "attach kind=SpinelBPF::") || strings.Contains(out, "attach kind=OK") {
		t.Errorf("attaching args[11] to sys_enter (2 arguments) must fail loudly")
	}
}

// rawtpFixture は testdata/trace の fixture を build・link して root で走らせた出力。
func rawtpFixture(t *testing.T, name string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "trace", name+".rb"))
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, name)
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe)
	t.Log(out)
	return out
}
