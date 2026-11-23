package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E114 の試験 (P026 — tracepoint の event の field): 生成物 (H1)・双子の smoke (H3)・実の attach の 2 段の差動と濾しの対照 (H4 — root)・
// load の前の tracefs の照合 (H5 — root)・attach の kind の取り違え (H6 — root)。負の例 (H2) は internal/frontend の testdata/neg の tp_*.rb (TestNegative)。

func tpSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_tracepoint.rb")
}

// tpWrites は H3 / H4 の write (fd・count・回数) と、その後の Out の値 (fd 900 の 4 回・count の和 7 × 3 + 11)。
var tpWrites = [][3]int{{900, 7, 3}, {901, 5, 2}, {900, 11, 1}}

var tpWant = []string{"Out[0]=4", "Out[1]=1", "Out[2]=32"}

// TestTracepointArtefacts は H1: .mlir の program の行と tp.field、schema の fields、ELF の requirements の版 11 と trace_tp・tpfield。
func TestTracepointArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(tpSrc())
	src := filepath.Join(d, "trace_tracepoint.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_tracepoint.mlir"))
	for _, w := range []string{`ebpf.program @on_write "tracepoint" attach "syscalls/sys_enter_write" maps [`, `ebpf.tp.field %ctx "fd" [16] : !ebpf.ctx<"tracepoint"> -> i64`, `ebpf.tp.field %ctx "count" [32] : !ebpf.ctx<"tracepoint"> -> i64`, `ebpf.tp.field %ctx "__syscall_nr" [8] : !ebpf.ctx<"tracepoint"> -> i32`, "arith.extsi"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_tracepoint.schema.json"))
	for _, w := range []string{`"kind": "tracepoint"`, `"attach_target": "syscalls/sys_enter_write"`, `"fields": [`, `"name": "__syscall_nr"`, `"offset": 32`} {
		if !strings.Contains(string(s), w) {
			t.Errorf("schema lacks %q:\n%s", w, s)
		}
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_tracepoint.bpf.o"))
	for _, w := range []string{"ebpf-requirements 11\n", "program\ton_write\ttracepoint\t5\n", "attach\ton_write\ttrace_tp\tsyscalls/sys_enter_write\ntpfield\ton_write\t__syscall_nr\t8\t4\ti\ntpfield\ton_write\tfd\t16\t8\tu\ntpfield\ton_write\tcount\t32\t8\tu\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// tpTwinRuns は双子の run の列 (tid の task の後に、write の回数だけ同じ field の値)。
func tpTwinRuns(b *strings.Builder) {
	for _, w := range tpWrites {
		for i := 0; i < w[2]; i++ {
			fmt.Fprintf(b, "run on_write __syscall_nr=1 fd=%d count=%d\n", w[0], w[1])
		}
	}
}

// TestTracepointTwinSmoke は H3: 双子の fd 900 の 3 回 (count 7)・901 の 2 回・900 の 1 回 (count 11) → Out[0]=4・Out[1]=1・Out[2]=32。
func TestTracepointTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_tracepoint")
	var in strings.Builder
	in.WriteString("reset\npoke Filter 0 4242\ntask 18219251273881\n") // tgid 4242 << 32 | tid 4249
	tpTwinRuns(&in)
	in.WriteString("dump\n")
	wantLines(t, feed(t, false, in.String(), tw), tpWant...)
}

// tpAttachDiff は H4 の 2 段の差動: kernel は sys_enter_write に attach した program に向けて harness の thread が write(fd, NULL, count) を
// (Filter は self なら own の tgid、でなければ tgid 1)、双子は同じ tid の task で同じ field の値を。
func tpAttachDiff(t *testing.T, h harnessSet, self bool) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	if self {
		ks.WriteString("pokeself Filter 0\n")
	} else {
		ks.WriteString("poke Filter 0 1\n") // tgid 1 (init) — 濾しの対照
	}
	ks.WriteString("self\n")
	for _, w := range tpWrites {
		fmt.Fprintf(&ks, "write %d %d %d\n", w[0], w[1], w[2])
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	tgid, _ := traceKernel(t, kernel)
	var tid int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tid=%d", &tid)
	}
	if tid == 0 {
		t.Fatalf("no tid from the write command:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	if self {
		fmt.Fprintf(&ts, "poke Filter 0 %d\n", tgid)
	} else {
		ts.WriteString("poke Filter 0 1\n")
	}
	fmt.Fprintf(&ts, "task %d\n", tgid<<32|tid)
	tpTwinRuns(&ts)
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestTracepointAttachDifferential は H4 (root): own の tgid と fd 900 で絞った kernel の dump がちょうど Out[0]=4・Out[1]=1・Out[2]=32 で
// 双子と一致、Filter を tgid 1 にすると kernel も双子も Out は全て 0。
func TestTracepointAttachDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, tpSrc())
	k, w := tpAttachDiff(t, h, true)
	t.Log(k)
	sameDump(t, "tracepoint attach", k, w)
	wantLines(t, k, tpWant...)
	k, w = tpAttachDiff(t, h, false)
	t.Log(k)
	sameDump(t, "tracepoint attach filtered", k, w)
	wantLines(t, k, "Out[0]=0", "Out[1]=0", "Out[2]=0")
}

// TestTracepointWrongField は H5 (a) (root、追補 1 の判定): fd を offset 24 の u64 と宣言した program は compile を通り、load が TargetRejected で
// tpfield の文 (field の名前は event で修飾 — `syscalls/sys_enter_write.fd`) と tracefs の正しい offset (16) を名指しして止まる。
func TestTracepointWrongField(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "tp_wrong_offset")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "reads tracepoint field syscalls/sys_enter_write.fd", "is at offset 16"} {
		if !strings.Contains(out, w) {
			t.Errorf("tp_wrong_offset: the load must stop on the tracefs format — want %q:\n%s", w, out)
		}
	}
}

// TestTracepointWrongWidth は H5 (b) (root なし、追補 1): fd を offset 16 の u32 と宣言した program は build で止まる — bpf-mlir の
// ebpf-schema-check が syscalls の event の BPF の context (nr は 8 の 4 byte、args は 16 + 8k の 8 byte) に無い field を拒否する。
func TestTracepointWrongWidth(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "trace", "tp_wrong_width.rb"))
	src := filepath.Join(d, "tp_wrong_width.rb")
	os.WriteFile(src, b, 0o644)
	_, err := Build(cfg, src)
	if err == nil || !strings.Contains(err.Error(), "is not part of the BPF context of syscalls events") {
		t.Fatalf("the build must stop on ebpf-schema-check (a 4-byte fd at 16 is not a syscalls event context slot), got %v", err)
	}
}

// TestTracepointAttachKind は H6 (root): tracepoint を raw_tp として・raw_tp を tracepoint として attach すると誤り、正しい kind は OK。
func TestTracepointAttachKind(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "tp_attach_kind")
	for _, w := range []string{"tracepoint as tracepoint kind=OK", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "tracepoint as raw_tp kind=SpinelBPF::") || !strings.Contains(out, "raw_tp as tracepoint kind=SpinelBPF::") {
		t.Errorf("attaching across raw_tp / tracepoint must fail loudly")
	}
}
