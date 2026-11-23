package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E115 の試験 (P026 — ksyscall と syscall の引数): 生成物 (H1)・双子の smoke (H3)・実の attach の 2 段の差動と濾しの対照 (H4 — root)・
// load の前の sysarg の照合 (H5 — root)・attach の kind の取り違え (H6 — root)。負の例 (H2) は internal/frontend の testdata/neg の ks_*.rb (TestNegative)。

func ksSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_ksyscall.rb")
}

// ksCalls は H3 / H4 の prctl (option・arg2〜arg5・回数) と、その後の Out の値。
var ksCalls = [][6]int64{{1158762496, 11, 22, 33, 44, 2}, {1158762496, 5, 6, 7, 1000, 1}, {1158762497, 1, 1, 1, 1, 1}}

var ksWant = []string{"Out[0]=3", "Out[1]=5", "Out[2]=6", "Out[3]=7", "Out[4]=1088"}

// TestKsyscallArtefacts は H1: .mlir の program の行と ksyscall.arg、schema、ELF の requirements の版 13 と ksyscall・arch・ctxfield・sysarg の並び。
func TestKsyscallArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(ksSrc())
	src := filepath.Join(d, "trace_ksyscall.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_ksyscall.mlir"))
	for _, w := range []string{`ebpf.program @on_prctl "ksyscall" attach "prctl" arch "x86_64" maps [`, `ebpf.ksyscall.arg %ctx 1 : !ebpf.ctx<"ksyscall"> -> i32`, "arith.extsi", `ebpf.ksyscall.arg %ctx 4 : !ebpf.ctx<"ksyscall"> -> i64`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_ksyscall.schema.json"))
	for _, w := range []string{`"kind": "ksyscall"`, `"attach_target": "prctl"`, `"arch": "x86_64"`, `"params": [`} {
		if !strings.Contains(string(s), w) {
			t.Errorf("schema lacks %q", w)
		}
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_ksyscall.bpf.o"))
	for _, w := range []string{"ebpf-requirements 13\n", "program\ton_prctl\tkprobe\t2\n", "helper\ton_prctl\tprobe_read_kernel\t113\n",
		"attach\ton_prctl\tksyscall\tprctl\narch\ton_prctl\tx86_64\nctxfield\ton_prctl\tpt_regs\tdi\t112\t8\nctxfield\ton_prctl\tpt_regs\tsi\t104\t8\nctxfield\ton_prctl\tpt_regs\tdx\t96\t8\nctxfield\ton_prctl\tpt_regs\tr10\t56\t8\nctxfield\ton_prctl\tpt_regs\tr8\t72\t8\nsysarg\ton_prctl\t1\ti32\nsysarg\ton_prctl\t2\tu64\nsysarg\ton_prctl\t3\tu64\nsysarg\ton_prctl\t4\tu64\nsysarg\ton_prctl\t5\tu64\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// ksTwinRuns は双子の run の列 (prctl の回数だけ同じ引数)。
func ksTwinRuns(b *strings.Builder) {
	for _, c := range ksCalls {
		for i := int64(0); i < c[5]; i++ {
			fmt.Fprintf(b, "run on_prctl a1=%d a2=%d a3=%d a4=%d a5=%d\n", c[0], c[1], c[2], c[3], c[4])
		}
	}
}

// TestKsyscallTwinSmoke は H3: 双子の 4 回の run → Out[0]=3・Out[1]=5・Out[2]=6・Out[3]=7・Out[4]=1088。
func TestKsyscallTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_ksyscall")
	var in strings.Builder
	in.WriteString("reset\npoke Filter 0 4242\ntask 18219251273881\n") // tgid 4242 << 32 | tid 4249
	ksTwinRuns(&in)
	in.WriteString("dump\n")
	wantLines(t, feed(t, false, in.String(), tw), ksWant...)
}

// ksAttachDiff は H4 (と H7) の 2 段の差動: kernel は prctl の wrapper に attach した program に向けて harness の thread が prctl を
// (Filter は self なら own の tgid、でなければ tgid 1)、双子は同じ tid の task で同じ引数を。
func ksAttachDiff(t *testing.T, h harnessSet, self bool) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n")
	for _, c := range ksCalls {
		fmt.Fprintf(&ks, "prctl %d %d %d %d %d %d\n", c[0], c[1], c[2], c[3], c[4], c[5])
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, _ := traceKernel(t, kernel)
	var tid int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tid=%d", &tid)
	}
	if tid == 0 {
		t.Fatalf("no tid from the prctl command:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	fmt.Fprintf(&ts, "task %d\n", tgid<<32|tid)
	ksTwinRuns(&ts)
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestKsyscallAttachDifferential は H4 (root): own の tgid と option で絞った kernel の dump がちょうど Out[0]=3・…・Out[3]=7 (r10)・Out[4]=1088
// で双子と一致、Filter を tgid 1 にすると kernel も双子も Out は全て 0。
func TestKsyscallAttachDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, ksSrc())
	k, w := ksAttachDiff(t, h, true)
	t.Log(k)
	sameDump(t, "ksyscall attach", k, w)
	wantLines(t, k, ksWant...)
	k, w = ksAttachDiff(t, h, false)
	t.Log(k)
	sameDump(t, "ksyscall attach filtered", k, w)
	wantLines(t, k, "Out[0]=0", "Out[1]=0", "Out[2]=0", "Out[3]=0", "Out[4]=0")
}

// TestKsyscallWrongType は H5 (root): prctl の第 1 引数を :u64 と宣言した program は compile を通り、load が TargetRejected
// (文の固定の部分 `reads syscall argument` と `prctl` だけを見る — E114 の教訓)。
func TestKsyscallWrongType(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "ks_wrong_type")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "reads syscall argument", "prctl"} {
		if !strings.Contains(out, w) {
			t.Errorf("ks_wrong_type: the load must stop on the syscall's format — want %q:\n%s", w, out)
		}
	}
}

// TestKsyscallAttachKind は H6 (root): ksyscall を kprobe として・kprobe を ksyscall として attach すると誤り、正しい kind は OK。
func TestKsyscallAttachKind(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "ks_attach_kind")
	for _, w := range []string{"ksyscall as ksyscall kind=OK", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "ksyscall as kprobe kind=SpinelBPF::") || !strings.Contains(out, "kprobe as ksyscall kind=SpinelBPF::") {
		t.Errorf("attaching across kprobe / ksyscall must fail loudly")
	}
}
