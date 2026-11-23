package main

import (
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E118 の試験 (P026 — kernel の struct の char * の member の先の文字列): 生成物 (H1)・双子の smoke (H3)・exec の実の attach の 2 段の差動 (H4 — root)・
// load の前の kfield strptr の照合 (H5 — root)。負の例 (H2) は internal/frontend の testdata/neg の kstr_*.rb (TestNegative)。

func kstrSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_kstr.rb")
}

// kstrPaths は H3 / H4 の exec の path (13 byte と 37 byte — 32 byte の member に切り詰め)。
var kstrPaths = []string{"/usr/bin/true", "/usr/bin/" + strings.Repeat("./", 12) + "true"}

// kstrWant は path の event の行 (name は先頭 31 byte と NUL・残りは 0、st は NUL を含む長さか 32)。
func kstrWant(i int, path string) []string {
	name := make([]byte, 32)
	n := len(path)
	if n > 31 {
		n = 31
	}
	copy(name, path[:n])
	return []string{fmt.Sprintf("Events#%d.name=%s", i, hex.EncodeToString(name)), fmt.Sprintf("Events#%d.st=%d", i, n+1)}
}

// kstrEvents は drain の行 (`Events#…` と `Events drained=…`)。
func kstrEvents(out string) []string {
	var ev []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); strings.HasPrefix(l, "Events#") || strings.HasPrefix(l, "Events drained=") {
			ev = append(ev, l)
		}
	}
	return ev
}

// TestKstrArtefacts は H1: .mlir の kernel.read_str と st の store_field、schema の strptr、ELF の requirements の版 15 と kfield strptr・helper 115。
func TestKstrArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(kstrSrc())
	src := filepath.Join(d, "trace_kstr.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "trace_kstr.mlir"))
	for _, w := range []string{`ebpf.kernel.read_str`, `"name", %`, `"filename" : !ebpf.reservation<!ebpf.record<"Ev", 40>>, !ebpf.kptr<"linux_binprm"> -> i64`, "ebpf.ringbuf.store_field"} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "trace_kstr.schema.json"))
	if !strings.Contains(strings.Join(strings.Fields(string(s)), ""), `"name":"filename","type":{"kind":"strptr"}`) {
		t.Errorf("schema: want filename as strptr:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "trace_kstr.bpf.o"))
	for _, w := range []string{"ebpf-requirements 15\n", "helper\ton_exec\tprobe_read_kernel_str\t115\n", "kfield\ton_exec\tlinux_binprm\tfilename\tstrptr\n", "attach\ton_exec\ttrace_fentry\tsecurity_bprm_check\nfarg\ton_exec\t0\tlinux_binprm\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// kstrTwin は双子の run の列 (exec ごとに Filter をその子の pid に、task も同じ pid)。
func kstrTwin(t *testing.T, tw string, pids []int64) string {
	t.Helper()
	var in strings.Builder
	in.WriteString("reset\n")
	for i, p := range kstrPaths {
		fmt.Fprintf(&in, "poke Filter 0 %d\ntask %d\nrun on_exec a0.filename=%s\n", pids[i], pids[i]<<32|pids[i], hex.EncodeToString([]byte(p)))
	}
	in.WriteString("drain Events\n")
	return feed(t, false, in.String(), tw)
}

// TestKstrTwinSmoke は H3: 双子の 2 つの event — "/usr/bin/true" (st 14) と 37 byte の path (先頭 31 byte と NUL・st 32)。
func TestKstrTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kstr")
	out := kstrTwin(t, tw, []int64{4242, 4243})
	var want []string
	for i, p := range kstrPaths {
		want = append(want, kstrWant(i, p)...)
	}
	wantLines(t, out, append(want, "Events drained=2")...)
}

// kstrDiff は H4 (と H6) の 2 段の差動: kernel は子を fork して Filter に子の pid を書いてから子が execve (2 回)、双子は同じ pid で同じ filename を。
func kstrDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("reset\n")
	for _, p := range kstrPaths {
		fmt.Fprintf(&ks, "exec Filter 0 %s\n", p)
	}
	ks.WriteString("drain Events\n")
	kernel = feed(t, true, ks.String(), h.kernelBin)
	var pids []int64
	for _, l := range strings.Split(kernel, "\n") {
		var c, st int64
		if n, _ := fmt.Sscanf(strings.TrimSpace(l), "child=%d status=%d", &c, &st); n == 2 {
			pids = append(pids, c)
		}
	}
	if len(pids) != len(kstrPaths) {
		t.Fatalf("want %d children, got %v:\n%s", len(kstrPaths), pids, kernel)
	}
	twin = kstrTwin(t, h.twinBin, pids)
	return
}

// TestKstrExecDifferential は H4 (root): kernel の ring の event がちょうど 2 つで H3 と同じ byte、双子と一致。
func TestKstrExecDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kstrSrc())
	k, w := kstrDiff(t, h)
	t.Log(k)
	if strings.Join(kstrEvents(k), "\n") != strings.Join(kstrEvents(w), "\n") {
		t.Errorf("kernel events differ from the twin:\nkernel:\n%s\ntwin:\n%s", strings.Join(kstrEvents(k), "\n"), strings.Join(kstrEvents(w), "\n"))
	}
	var want []string
	for i, p := range kstrPaths {
		want = append(want, kstrWant(i, p)...)
	}
	wantLines(t, k, append(want, "Events drained=2")...)
}

// TestKstrStrptrOnInt は H5 (root): argc (int) を :strptr と宣言した program は compile を通り、load が TargetRejected。
func TestKstrStrptrOnInt(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "ks_strptr_on_int")
	if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") {
		t.Errorf("ks_strptr_on_int: the load must stop on the target's BTF (kfield strptr):\n%s", out)
	}
}
