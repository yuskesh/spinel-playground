package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E142 の試験 (P028 — tracepoint の :user_str の field、bpf-mlir E546): 生成物 (H1)・双子の smoke (H3)・sys_enter_openat の 4 つの event の 2 段の差動
// (H4 — root、Filter の窓)・load の前の tpfield strptr の照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の tps_*.rb
// (TestNegative)、変異 (H6) は e142_mutation_test.go。H0 (tracefs の format の記録) は root の段の手順 0。

func tpStrSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_tp_user_str.rb")
}

// e142Paths は H4 の openat の path (短い・40 文字 — 先頭 31 byte と NUL に切り詰め・空・NULL)。
var e142Paths = []string{"/nonexistent-e142", "/nonexistent-e142-0123456789abcdefghijkl", "@empty", "@null"}

// TestTpStrArtefacts は H1: .mlir の tp.field -> !ebpf.user_str と read_str、schema の {kind: user_str}、requirements の形式 16 と tpfield strptr。
func TestTpStrArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(tpStrSrc())
	src := filepath.Join(d, "trace_tp_user_str.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_tp_user_str.mlir"))
	for _, w := range []string{`ebpf.tp.field %ctx "filename" [24] : !ebpf.ctx<"tracepoint"> -> !ebpf.user_str`, "ebpf.user.read_str"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_tp_user_str.schema.json"))
	if !strings.Contains(string(s), `"kind": "user_str"`) {
		t.Errorf("schema lacks the user_str field type:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_tp_user_str.bpf.o"))
	for _, w := range []string{"ebpf-requirements 16\n", "tpfield\ton_open\tfilename\t24\t8\tstrptr\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// strHex は s の byte を n byte に 0 で埋めた hex (双子の smoke の期待だけ — H4 は双子との差動)。
func strHex(s string, n int) string {
	b := make([]byte, n)
	copy(b, s)
	return fmt.Sprintf("%x", b)
}

// TestTpStrTwinSmoke は H3: 双子の短い path は name と status 16、NULL は 0 の name と −14。
func TestTpStrTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_tp_user_str")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_open __syscall_nr=257 filename=/tmp/e142-short\nrun on_open __syscall_nr=257 filename=@null\ndrain Events\n", tw)
	t.Log(out)
	wantLines(t, out, "Events#0.name="+strHex("/tmp/e142-short", 32), "Events#0.status=16", "Events#0.nr=257",
		"Events#1.name="+strHex("", 32), "Events#1.status=-14", "Events drained=2")
}

// tpStrDiff は H4 (と H6) の 2 段の差動 (E146 追補 1 と同じ窓): kernel は Filter に自分の tgid を書いた直後に 4 つの openat、直後に Filter を 0 に、
// 双子は同じ tgid・tid と path。
func tpStrDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\nself\npokeself Filter 0\n")
	for _, p := range e142Paths {
		ks.WriteString("openat " + p + " 1\n")
	}
	ks.WriteString("poke Filter 0 0\ndrain Events\ndump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	var tgid int64
	var tids []int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tgid=%d", &tgid)
		var v int64
		if _, err := fmt.Sscanf(l, "tid=%d", &v); err == nil {
			tids = append(tids, v)
		}
	}
	if tgid == 0 || len(tids) != len(e142Paths) {
		t.Fatalf("want tgid and %d tids in the kernel harness output:\n%s", len(e142Paths), kernel)
	}
	var ts strings.Builder
	ts.WriteString(fmt.Sprintf("reset\npoke Filter 0 %d\n", tgid))
	for i, p := range e142Paths {
		ts.WriteString(fmt.Sprintf("task %d\nrun on_open __syscall_nr=257 filename=%s\n", tgid<<32|tids[i], p))
	}
	ts.WriteString("poke Filter 0 0\ndrain Events\ndump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestTpStrDifferential は H4 (root): kernel の event がちょうど 4 つ — status 18 (短い)・32 (切り詰め)・1 (空 — 7.1.8)・−14 (NULL)、nr 257、
// drain の行と dump が双子と byte 同じ。
func TestTpStrDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, tpStrSrc())
	k, w := tpStrDiff(t, h)
	t.Log(k)
	kr, wr := ringLines(k), ringLines(w)
	if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
		t.Errorf("ring events differ\nkernel:\n%s\ntwin:\n%s", strings.Join(kr, "\n"), strings.Join(wr, "\n"))
	}
	wantLines(t, k, "Events#0.status=18", "Events#1.status=32", "Events#2.status=1", "Events#3.status=-14",
		"Events#0.nr=257", "Events#3.nr=257", "Events drained=4", "Out[0]=4")
	sameDump(t, "tracepoint user_str", k, w)
}

// TestTpStrLoadCheck は H5 (root): int の flags を :user_str と宣言した program は compile を通り、load が TargetRejected (文の固定の部分
// `program on_bad ` だけ — 追補 2: tpfield の文は program の名前の後に「:」を置かない (1 回目の run の外れ))。
func TestTpStrLoadCheck(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "tp_str_on_int")
	for _, w := range []string{"load kind=SpinelBPF::TargetRejected", "program on_bad "} {
		if !strings.Contains(out, w) {
			t.Errorf("tp_str_on_int: the load must stop on tpfield strptr (the field is not a char *) — want %q:\n%s", w, out)
		}
	}
}
