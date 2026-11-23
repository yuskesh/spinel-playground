package main

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// E089 の試験 (P021 の段 C): 配列の field の写し (`r.load.m = t.copy(:f)`) と fentry の struct の引数 (`args:` と ctx.kptr_or_null)。

func tComm() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tpbtf", "t_comm.rb")
}

func tFentry() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tpbtf", "t_fentry.rb")
}

// commBytes は dump の Recs[0].comm[0..15] の値の hex (dump の無い要素は誤り)。
func commBytes(t *testing.T, out string) string {
	t.Helper()
	var b strings.Builder
	for i := 0; i < 16; i++ {
		p := fmt.Sprintf("Recs[0].comm[%d]=", i)
		j := strings.Index(out, p)
		if j < 0 {
			t.Fatalf("no %s in:\n%s", p, out)
		}
		v, _ := strconv.Atoi(strings.SplitN(out[j+len(p):], "\n", 2)[0])
		fmt.Fprintf(&b, "%02x", v)
	}
	return b.String()
}

// TestTpBtfCommDifferential は E089 の H3 (host、root): t_comm の attach の後に `comm e089comm` と fork × N で、kernel の Recs[0].comm が harness の
// PR_GET_NAME の 16 byte と同じ・数 N・pid は最後の子。双子に同じ 16 byte (`a1.comm=<hex>`) を与えた run の Recs と Out が一致。双子の配列の値は
// 16 byte を越えると止まる。
func TestTpBtfCommDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, tComm())
	const n = 4
	kn := feed(t, true, "reset\nself\npokeself Cfg 0\ncomm e089comm\n"+strings.Repeat("fork\n", n)+"dump\n", h.kernelBin)
	var tgid, comm string
	var children []string
	for _, l := range strings.Split(kn, "\n") {
		switch {
		case strings.HasPrefix(l, "tgid="):
			tgid = strings.TrimPrefix(l, "tgid=")
		case strings.HasPrefix(l, "comm="):
			comm = strings.TrimPrefix(l, "comm=")
		case strings.HasPrefix(l, "child="):
			children = append(children, strings.TrimPrefix(l, "child="))
		}
	}
	if tgid == "" || len(children) != n || comm != "65303839636f6d6d0000000000000000" {
		t.Fatalf("kernel harness output (want comm=e089comm padded with NUL):\n%s", kn)
	}
	var ts strings.Builder
	ts.WriteString("reset\npoke Cfg 0 " + tgid + "\n")
	for _, c := range children {
		ts.WriteString("run on_fork a0.tgid=" + tgid + " a1.pid=" + c + " a1.tgid=" + c + " a1.comm=" + comm + "\n")
	}
	ts.WriteString("dump\nrun on_fork a1.comm=" + comm + "00\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	if got := commBytes(t, kn); got != comm {
		t.Errorf("kernel: Recs[0].comm = %s, want %s", got, comm)
	}
	if got := commBytes(t, tw); got != comm {
		t.Errorf("twin: Recs[0].comm = %s, want %s", got, comm)
	}
	last := children[n-1]
	for _, w := range []string{"Out[0]=" + strconv.Itoa(n) + "\n", "Recs[0].pid=" + last + "\n"} {
		if !strings.Contains(kn, w) || !strings.Contains(tw, w) {
			t.Errorf("want %q in both:\nkernel:\n%s\ntwin:\n%s", w, kn, tw)
		}
	}
	if !strings.HasSuffix(strings.TrimSpace(tw), "err=RuntimeError") {
		t.Errorf("twin: a 17-byte comm value should stop:\n%s", tw)
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}

// TestFentryArgsDifferential は E089 の H4 (host、root): t_fentry の attach の後に tracing の test run × N (bpf_fentry_test7(NULL)・
// bpf_fentry_test8(&{a: NULL})) と fork × M で、kernel の Out が test7 の absent N・present 0、test8 の present N と a の absent N、wake_up_new_task の
// present M・最後の p の pid = 最後の子。双子に同じ値を kernel の task (tgid と test run の tid) と与えた run と dump が一致。
func TestFentryArgsDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, tFentry())
	const n, m = 3, 2
	kn := feed(t, true, "reset\nself\npokeself Cfg 0\n"+strings.Repeat("run on_t7\n", n)+strings.Repeat("fork\n", m)+"dump\n", h.kernelBin)
	tg, tids := traceKernel(t, kn)
	var children []string
	for _, l := range strings.Split(kn, "\n") {
		if strings.HasPrefix(l, "child=") {
			children = append(children, strings.TrimPrefix(l, "child="))
		}
	}
	if len(tids) != n || len(children) != m {
		t.Fatalf("kernel harness output:\n%s", kn)
	}
	var ts strings.Builder
	fmt.Fprintf(&ts, "reset\npoke Cfg 0 %d\n", tg)
	for _, tid := range tids {
		fmt.Fprintf(&ts, "task %d\nrun on_t7 a0=null\nrun on_t8\n", tg<<32|tid)
	}
	for _, c := range children {
		fmt.Fprintf(&ts, "task %d\nrun on_wake a0.pid=%s a0.tgid=%s\n", tg<<32|tg, c, c)
	}
	ts.WriteString("dump\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	sameDump(t, "fentry args", kn, tw)
	ns, ms := strconv.Itoa(n), strconv.Itoa(m)
	for _, w := range []string{"Out[0]=0", "Out[1]=" + ns, "Out[2]=" + ns, "Out[3]=0", "Out[4]=" + ns, "Out[5]=" + ms, "Out[6]=" + children[m-1], "Out[7]=0"} {
		if !strings.Contains(kn, w+"\n") {
			t.Errorf("kernel: want %q in\n%s", w, kn)
		}
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}

// TestKernelTypeCopyFargControls は E089 の H5 (host、root): comm を `[:u8, 8]` と宣言した source (record も 8) と、bpf_fentry_test7 の引数を
// task_struct と宣言した source は build が通り load が TargetRejected (kfield / farg)。正しい宣言の load は通る。
func TestKernelTypeCopyFargControls(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	same := func(s string) string { return s }
	for _, c := range []struct {
		name, prog     string
		rewrite        func(string) string
		want, wantKind string
	}{
		{"control comm", "tpbtf_comm", same, "load ok unmet=", ""},
		{"control fentry", "fentry_args", same, "load ok unmet=", ""},
		{"comm [:u8, 8]", "tpbtf_comm", func(s string) string {
			s = strings.Replace(s, "comm: [:u8, 16])\nTaskT", "comm: [:u8, 8])\nTaskT", 1)
			s = strings.Replace(s, "Task.new(0, 0, 0, Array.new(16, 0))", "Task.new(0, 0, 0, Array.new(8, 0))", 1)
			s = strings.Replace(s, "BPF.record(Ev, comm: [:u8, 16]", "BPF.record(Ev, comm: [:u8, 8]", 1)
			return strings.Replace(s, "Ev.new(Array.new(16, 0), 0)", "Ev.new(Array.new(8, 0), 0)", 1)
		}, "load kind=SpinelBPF::TargetRejected", "reads task_struct.comm as [8]u8"},
		{"fentry test8 arg as task_struct", "fentry_args", func(s string) string {
			i := strings.Index(s, "def on_t8(ctx)")
			return s[:i] + "def on_t8(ctx)\n  t = ctx.kptr_or_null(0, TaskT)\n  if t\n    Out.update(3, t.load.pid & 0xFFFFFFFF)\n  end\nend\nBPF.fentry :on_t8, \"bpf_fentry_test8\", args: {0 => [:or_null, TaskT]}\n"
		}, "load kind=SpinelBPF::TargetRejected", "not struct task_struct"},
	} {
		out := tpbtfLoad(t, c.prog, c.rewrite)
		t.Logf("%s: %s", c.name, firstLines(out, 3))
		if !strings.Contains(out, c.want) || (c.wantKind != "" && !strings.Contains(out, c.wantKind)) {
			t.Errorf("%s: want %q and %q, got\n%s", c.name, c.want, c.wantKind, out)
		}
	}
}
