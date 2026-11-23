package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E151 の試験 (P028 — argv、bpf-mlir E548): 生成物 (H1)・双子の smoke (H3)・自分の子の execve の argv の列の 2 段の差動 (H4 — root、ksyscall と
// tracepoint)・load の前の sysarg strarray の照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の arv_*.rb (TestNegative)、
// 変異 (H6) は e151_mutation_test.go。execsnoop (H7) は e151_bcc_test.go。

func argvSrc(n string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", n+".rb")
}

// e151Argvs は H4 の argv の列 (harness の execargv の綴り — `,` 区切り・@e は空・@null は 0 個) と kernel の event の数の予測。
var e151Argvs = []struct {
	csv  string
	want int
}{{"@null", 0}, {"x", 1}, {"a,bb,@e", 3}, {argvWords(20), 20}, {argvWords(21), 20}}

func argvWords(n int) string {
	var w []string
	for i := 0; i < n; i++ {
		w = append(w, fmt.Sprintf("w%d", i))
	}
	return strings.Join(w, ",")
}

// TestArgvArtefacts は H1: 20 の str_at (ebpf.loop の外)、schema の user_str_array、requirements の形式 16 と strarray (ksyscall と tracepoint)。
func TestArgvArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	for _, c := range []struct{ n, op, req string }{
		{"trace_argv", `ebpf.ksyscall.arg %ctx 2 : !ebpf.ctx<"ksyscall"> -> !ebpf.user_str_array`, "sysarg\ton_exec\t2\tstrarray\n"},
		{"trace_argv_tp", `ebpf.tp.field %ctx "argv" [24] : !ebpf.ctx<"tracepoint"> -> !ebpf.user_str_array`, "tpfield\ton_exec\targv\t24\t8\tstrarray\n"},
	} {
		d := t.TempDir()
		b, _ := os.ReadFile(argvSrc(c.n))
		src := filepath.Join(d, c.n+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		m, _ := os.ReadFile(filepath.Join(d, c.n+".mlir"))
		s := string(m)
		if !strings.Contains(s, c.op) || strings.Count(s, "ebpf.user.str_at") != 20 || strings.Contains(s, "ebpf.loop") {
			t.Errorf("%s .mlir: want %q, 20 str_at and no ebpf.loop (got %d str_at)", c.n, c.op, strings.Count(s, "ebpf.user.str_at"))
		}
		for k := 0; k < 20; k++ {
			if !strings.Contains(s, fmt.Sprintf(" [%d] : !ebpf.user_str_array -> (!ebpf.user_str, i64, i1)", k)) {
				t.Errorf("%s .mlir lacks str_at [%d]", c.n, k)
			}
		}
		sc, _ := os.ReadFile(filepath.Join(d, c.n+".schema.json"))
		if !strings.Contains(string(sc), `"kind": "user_str_array"`) {
			t.Errorf("%s schema lacks user_str_array", c.n)
		}
		r := elfRequirements(t, cfg, filepath.Join(d, c.n+".bpf.o"))
		for _, w := range []string{"ebpf-requirements 16\n", c.req} {
			if !strings.Contains(string(r), w) {
				t.Errorf("%s requirements lack %q:\n%s", c.n, w, r)
			}
		}
	}
}

// TestArgvTwinSmoke は H3: 双子の argv `a,bb,` (3 個 — 最後は空) → event 3 つ (index 0 / 1 / 2、status 2 / 3 / 1)。
func TestArgvTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_argv")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251277922\nrun on_exec a2=a,bb,@e\ndrain Events\n", tw) // 4242 << 32 | 4242
	t.Log(out)
	wantLines(t, out, "Events#0.index=0", "Events#0.arg="+strHex("a", 32), "Events#0.status=2",
		"Events#1.index=1", "Events#1.arg="+strHex("bb", 32), "Events#1.status=3",
		"Events#2.index=2", "Events#2.arg="+strHex("", 32), "Events#2.status=1", "Events drained=3")
}

// argvDiff は H4 (と H6) の 2 段の差動: kernel は argv の列ごとに子を execargv (子の pid を Filter に書いてから execve) して drain、
// 双子は同じ子の pid と argv を key (ksyscall は a2、tracepoint は argv) で。
func argvDiff(t *testing.T, h harnessSet, key string) (kernel, twin []string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	for _, a := range e151Argvs {
		ks.WriteString("execargv Filter 0 " + a.csv + "\ndrain Events\necho step\n")
	}
	k := feed(t, true, ks.String(), h.kernelBin)
	t.Log(k)
	var kids []int64
	for _, l := range strings.Split(k, "\n") {
		var c, st int64
		if _, err := fmt.Sscanf(l, "child=%d status=%d", &c, &st); err == nil {
			kids = append(kids, c)
		}
	}
	if len(kids) != len(e151Argvs) {
		t.Fatalf("want %d children, got %v:\n%s", len(e151Argvs), kids, k)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	for i, a := range e151Argvs {
		ts.WriteString(fmt.Sprintf("poke Filter 0 %d\ntask %d\nrun on_exec %s=%s\ndrain Events\necho step\n", kids[i], kids[i]<<32|kids[i], key, a.csv))
	}
	w := feed(t, false, ts.String(), h.twinBin)
	return strings.Split(k, "## step\n"), strings.Split(w, "## step\n")
}

// argvDifferential は H4: 各段の kernel の event の数が予測 (0 / 1 / 3 / 20 / 20) で、drain の行が双子と byte 同じ。
func argvDifferential(t *testing.T, src, key string) {
	h := buildHarnesses(t, argvSrc(src))
	k, w := argvDiff(t, h, key)
	for i, a := range e151Argvs {
		kr, wr := ringLines(k[i]), ringLines(w[i])
		t.Logf("%s step %d (%s): kernel %d lines", src, i, a.csv, len(kr))
		if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
			t.Errorf("%s step %d: ring events differ\nkernel:\n%s\ntwin:\n%s", src, i, strings.Join(kr, "\n"), strings.Join(wr, "\n"))
		}
		wantLines(t, k[i], fmt.Sprintf("Events drained=%d", a.want))
	}
}

// TestArgvDifferential は H4 (root — ksyscall の execve)。
func TestArgvDifferential(t *testing.T) {
	requireUnverified(t)
	argvDifferential(t, "trace_argv", "a2")
}

// TestArgvTpDifferential は H4 (root — tracepoint の sys_enter_execve)。
func TestArgvTpDifferential(t *testing.T) {
	requireUnverified(t)
	argvDifferential(t, "trace_argv_tp", "argv")
}

// TestArgvLoadCheck は H5 (root): execve の filename (char * — 深度 1) を :user_str_array と宣言した program は load が TargetRejected で文に on_bad を含む。
func TestArgvLoadCheck(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "av_str_as_array")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "on_bad"} {
		if !strings.Contains(out, w) {
			t.Errorf("av_str_as_array: the load must stop on sysarg strarray (filename is a char *, not char **) — want %q:\n%s", w, out)
		}
	}
}
