package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E117 の試験 (P026 — fentry の整数の引数): 生成物 (H1)・双子の smoke (H3)・test run の 2 段の差動と濾しの対照 (H4 — root)・load の前の farg の
// 照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の fe_*.rb と kc_fentry_*.rb (TestNegative)。

func fentryIntSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_fentry_int.rb")
}

// fentryIntRun は双子の 1 回の run (kernel の test run が bpf_fentry_test6 を呼ぶ値 — 16・(17)・18・19・(20)・21)。
const fentryIntRun = "run on_t6 a0=16 a2=18 a3=19 a5=21\n"

var fentryIntWant = []string{"Out[0]=3", "Out[1]=16", "Out[2]=18", "Out[3]=19", "Out[4]=63"}

// TestFentryIntArtefacts は H1: .mlir の ctx.arg の slot と幅、schema の args の位置の配列、ELF の requirements の版 8 と farg の行。
func TestFentryIntArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(fentryIntSrc())
	src := filepath.Join(d, "trace_fentry_int.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_fentry_int.mlir"))
	for _, w := range []string{`ebpf.program @on_t6 "fentry" attach "bpf_fentry_test6"`, `ebpf.ctx.arg %ctx[0] : !ebpf.ctx<"fentry"> -> i64`, `ebpf.ctx.arg %ctx[2] : !ebpf.ctx<"fentry"> -> i16`, `ebpf.ctx.arg %ctx[3] : !ebpf.ctx<"fentry"> -> i32`, `ebpf.ctx.arg %ctx[5] : !ebpf.ctx<"fentry"> -> i64`, "arith.extsi"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_fentry_int.bpf.o"))
	for _, w := range []string{"ebpf-requirements 8\n", "attach\ton_t6\ttrace_fentry\tbpf_fentry_test6\nfarg\ton_t6\t0\tu64\nfarg\ton_t6\t1\t-\nfarg\ton_t6\t2\ti16\nfarg\ton_t6\t3\ti32\nfarg\ton_t6\t4\t-\nfarg\ton_t6\t5\tu64\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestFentryIntTwinSmoke は H3: 双子の 3 回の run → Out[0]=3・Out[1]=16・Out[2]=18・Out[3]=19・Out[4]=63。
func TestFentryIntTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_fentry_int")
	in := "reset\npoke Filter 0 4242\ntask 18219251273881\n" + strings.Repeat(fentryIntRun, 3) + "dump\n" // tgid 4242 << 32 | tid 4249
	wantLines(t, feed(t, false, in, tw), fentryIntWant...)
}

// fentryIntDiff は H4 (と H6) の 2 段の差動: kernel は test run (bml の短命の thread — kernel が bpf_fentry_test6 を呼ぶ) を 3 回、双子は同じ tid の
// task で kernel の値を。Filter は self なら own の tgid、でなければ tgid 1。
func fentryIntDiff(t *testing.T, h harnessSet, self bool) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n" + strings.Repeat("run on_t6\n", 3) + "dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, tids := traceKernel(t, kernel)
	if len(tids) != 3 {
		t.Fatalf("want 3 tids, got %v:\n%s", tids, kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		ts.WriteString("poke Filter 0 " + fmt.Sprint(tgid) + "\n")
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	for _, tid := range tids {
		ts.WriteString("task " + fmt.Sprint(tgid<<32|tid) + "\n" + fentryIntRun)
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestFentryIntDifferential は H4 (root): own の tgid で絞った kernel の dump がちょうど Out[0]=3・16・18・19・63 で双子と一致、
// Filter を tgid 1 にすると kernel も双子も全て 0。
func TestFentryIntDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, fentryIntSrc())
	k, w := fentryIntDiff(t, h, true)
	t.Log(k)
	sameDump(t, "fentry int", k, w)
	wantLines(t, k, fentryIntWant...)
	k, w = fentryIntDiff(t, h, false)
	t.Log(k)
	sameDump(t, "fentry int filtered", k, w)
	wantLines(t, k, "Out[0]=0", "Out[1]=0", "Out[2]=0", "Out[3]=0", "Out[4]=0")
}

// TestFentryIntWrongDecl は H5 (root): d を :u32・b (void *) を :u64 と宣言した program は compile を通り、load が TargetRejected
// (文の固定の部分 `program on_bad:` だけを見る — bml の farg の Detail の接頭辞)。
func TestFentryIntWrongDecl(t *testing.T) {
	requireUnverified(t)
	for _, n := range []string{"fe_wrong_sign", "fe_int_on_ptr"} {
		out := rawtpFixture(t, n)
		for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "program on_bad:"} {
			if !strings.Contains(out, w) {
				t.Errorf("%s: the load must stop on the target's FUNC_PROTO (farg) — want %q:\n%s", n, w, out)
			}
		}
	}
}
