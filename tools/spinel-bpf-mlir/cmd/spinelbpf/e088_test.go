package main

import (
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// E088 の試験 (P021 の段 B): nullable の引数 (ctx.kptr_or_null) と pointer の field (t.ptr) と if → ebpf.kptr.check。

func tChase() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tpbtf", "t_chase.rb")
}

func tPi() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tpbtf", "t_pi.rb")
}

// TestTpBtfNullTwin は双子の pointer の member と nullable の引数: `a<i>.<m>=present` と `a<i>.<m>.<f>=v` が先を作り、与えない pointer は NULL、
// `a<i>=null` は nullable の引数を nil に。宣言に無い名前 (整数の member の先・宣言に無い pointer) は止まる。kernel の harness は `pi` を持つ。
func TestTpBtfNullTwin(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	bin, _, _ := buildTwinOnly(t, tChase())
	out := feed(t, false, "reset\npoke Cfg 0 77\nrun on_fork a0.tgid=77 a1.pid=9 a1.tgid=9 a1.real_parent=present a1.real_parent.tgid=77 a1.mm=present\n"+
		"run on_fork a0.tgid=77 a1.pid=10 a1.tgid=10 a1.vfork_done=present\nrun on_fork a0.tgid=77 a1.pid=11 a1.tgid=12\ndump\nrun on_fork a1.pid.tgid=1\nrun on_fork a1.parent=present\n", bin)
	for _, w := range []string{"Out[0]=2\n", "Out[1]=77\n", "Out[2]=1000000\n", "Out[3]=1\n", "err=RuntimeError\nerr=RuntimeError\n"} {
		if !strings.Contains(out, w) {
			t.Errorf("chase twin: want %q in:\n%s", w, out)
		}
	}
	pb, _, kh := buildTwinOnly(t, tPi())
	po := feed(t, false, "reset\npoke Cfg 0 5\nrun on_pi a0.tgid=5 a1.pid=42\nrun on_pi a0.tgid=5 a1=null\nrun on_pi a0.tgid=5 a1=null\nrun on_pi a0.tgid=6 a1.pid=43\ndump\n", pb)
	for _, w := range []string{"Out[0]=1\n", "Out[1]=2\n", "Out[2]=42\n"} {
		if !strings.Contains(po, w) {
			t.Errorf("pi twin: want %q in:\n%s", w, po)
		}
	}
	for _, w := range []string{`_h_cmd == "pi"`, "HTrace.h_pi", "PTHREAD_PRIO_INHERIT"} {
		if !strings.Contains(kh, w) {
			t.Errorf("the kernel harness lacks %q", w)
		}
	}
	t.Logf("chase twin:\n%s\npi twin:\n%s", out, po)
}

// TestTpBtfChaseDifferential は E088 の H3 (host、root): t_chase の attach の後に fork × N で、kernel の Out が「数 N・real_parent の tgid = harness の
// tgid・vfork_done が NULL の回 N・mm の在る回 N」、双子に同じ値を与えた run と一致。
func TestTpBtfChaseDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, tChase())
	const n = 5
	kn := feed(t, true, "reset\nself\npokeself Cfg 0\n"+strings.Repeat("fork\n", n)+"dump\n", h.kernelBin)
	var tgid string
	var children []string
	for _, l := range strings.Split(kn, "\n") {
		switch {
		case strings.HasPrefix(l, "tgid="):
			tgid = strings.TrimPrefix(l, "tgid=")
		case strings.HasPrefix(l, "child="):
			children = append(children, strings.TrimPrefix(l, "child="))
		}
	}
	if tgid == "" || len(children) != n {
		t.Fatalf("kernel harness output:\n%s", kn)
	}
	var ts strings.Builder
	ts.WriteString("reset\npoke Cfg 0 " + tgid + "\n")
	for _, c := range children {
		ts.WriteString("run on_fork a0.tgid=" + tgid + " a1.pid=" + c + " a1.tgid=" + c + " a1.real_parent=present a1.real_parent.tgid=" + tgid + " a1.mm=present\n")
	}
	ts.WriteString("dump\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	ns := strconv.Itoa(n)
	for _, w := range []string{"Out[0]=" + ns, "Out[1]=" + tgid, "Out[2]=" + ns, "Out[3]=" + ns} {
		if !strings.Contains(kn, w+"\n") {
			t.Errorf("kernel: want %q in\n%s", w, kn)
		}
		if !strings.Contains(tw, w+"\n") {
			t.Errorf("twin: want %q in\n%s", w, tw)
		}
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}

// TestTpBtfPiDifferential は E088 の H4 (host、root): t_pi の attach の後に `pi 5` で kernel の present ≥ 5・absent ≥ 5・最後の pi_task の pid = 最後の
// 待つ thread の tid。双子に kernel と同じ回数の present (最後の pid) / absent (`a1=null`) を与えた run と Out が一致。
func TestTpBtfPiDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	h := buildHarnesses(t, tPi())
	kn := feed(t, true, "reset\nself\npokeself Cfg 0\npi 5\ndump\n", h.kernelBin)
	var tgid, waiter string
	out := map[string]int{}
	for _, l := range strings.Split(kn, "\n") {
		switch {
		case strings.HasPrefix(l, "tgid="):
			tgid = strings.TrimPrefix(l, "tgid=")
		case strings.HasPrefix(l, "waiter="):
			waiter = strings.TrimPrefix(l, "waiter=")
		case strings.HasPrefix(l, "Out["):
			k, v, _ := strings.Cut(l, "=")
			out[k], _ = strconv.Atoi(v)
		}
	}
	if tgid == "" || waiter == "" || strings.HasPrefix(waiter, "-") {
		t.Fatalf("kernel harness output:\n%s", kn)
	}
	if out["Out[0]"] < 5 || out["Out[1]"] < 5 || strconv.Itoa(out["Out[2]"]) != waiter {
		t.Errorf("kernel: want present >= 5, absent >= 5, last pi_task pid = %s:\n%s", waiter, kn)
	}
	var ts strings.Builder
	ts.WriteString("reset\npoke Cfg 0 " + tgid + "\n")
	for i := 0; i < out["Out[1]"]; i++ {
		ts.WriteString("run on_pi a0.tgid=" + tgid + " a1=null\n")
	}
	for i := 0; i < out["Out[0]"]; i++ {
		ts.WriteString("run on_pi a0.tgid=" + tgid + " a1.pid=" + waiter + "\n")
	}
	ts.WriteString("dump\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	for _, k := range []string{"Out[0]", "Out[1]", "Out[2]"} {
		w := k + "=" + strconv.Itoa(out[k]) + "\n"
		if !strings.Contains(tw, w) {
			t.Errorf("twin: want %q in\n%s", w, tw)
		}
	}
	t.Logf("kernel:\n%s\ntwin:\n%s", kn, tw)
}

// TestTpBtfNullableDeclaredNonNull は E088 の H5 (host、root): sched_pi_setprio の引数 1 (pi_task — nullable) を非 null と宣言して ctx.kptr で読む
// program は build も load の前の照合も通り、load の verifier が拒否する (SpinelBPF::VerifierRejected、log に trusted_ptr_or_null)。正しい宣言
// (tpbtf_pi) の load は通る (対照)。
func TestTpBtfNullableDeclaredNonNull(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046
	ctl := tpbtfLoad(t, "tpbtf_pi", func(s string) string { return s })
	if !strings.Contains(ctl, "load ok unmet=") {
		t.Errorf("control tpbtf_pi: want load ok, got\n%s", ctl)
	}
	bad := tpbtfLoad(t, "tpbtf_pi", func(s string) string {
		i := strings.Index(s, "def on_pi(ctx)")
		return s[:i] + "def on_pi(ctx)\n  pi = ctx.kptr(1, TaskT)\n  Out.update(2, pi.load.pid & 0xFFFFFFFF)\nend\nBPF.tp_btf :on_pi, \"sched_pi_setprio\", args: {0 => TaskT, 1 => TaskT}\n"
	})
	t.Logf("control: %s\nnon-null: %s", firstLines(ctl, 2), firstLines(bad, 6))
	if !strings.Contains(bad, "load kind=SpinelBPF::VerifierRejected") || !strings.Contains(bad, "trusted_ptr_or_null") {
		t.Errorf("non-null declared: want VerifierRejected with trusted_ptr_or_null, got\n%s", bad)
	}
}
