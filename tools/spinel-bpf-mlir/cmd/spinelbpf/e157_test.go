package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E157 の試験 (P029 §2 段 4 — uprobe の :ptr): 子の mfix の pthread_mutex_lock / unlock の差動 (H3)・変異 (H4 — e157_mutation_test.go)・deadlock (H5)。

func mfixPath() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", "target", "mfix")
}

// sysHarnesses は buildHarnesses (e009) と同じ双子と kernel の harness — target が絶対の path (libc) の source 用 (kernel の harness に source の dir を
// 渡さない — e009 の共有の helper を変えない、E156 の gaiHarnesses と同じ形)。
func sysHarnesses(t *testing.T, name string) harnessSet {
	t.Helper()
	cfg, _ := defaultConfig()
	src := uprobeSrc(name)
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := frontend.TwinHarness(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	td := t.TempDir()
	base := name + ".rb"
	twinSrc := filepath.Join(td, base)
	os.WriteFile(twinSrc, []byte(tw), 0o644)
	twinBin := filepath.Join(td, "twin")
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), base, "-o", twinBin)
	c.Dir, c.Env = td, append(os.Environ(), "TMPDIR="+td)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s", err, o)
	}
	return harnessSet{twinBin: twinBin, twinSrc: twinSrc, kernelBin: buildKernelHarness(t, cfg, base, string(text), res)}
}

// lockRows は H3 の mfix の命令 (AB-BA): lock 0・lock 1・unlock 1・unlock 0・lock 1・lock 0。
var lockRows = []string{"lock 0", "lock 1", "unlock 1", "unlock 0", "lock 1", "lock 0"}

// lockDiff は 2 段の差動: kernel は子の mfix に命令を送り (lock の答えの mutex の address を rv= に)、双子は lock の行を `at <rv>` で、
// unlock の行をそのまま走らせる。返すのは rv= の行を除き child の行を揃えた kernel の出力・双子の出力・address の列。
func lockDiff(t *testing.T, h harnessSet) (kernel, twin string, addrs []string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("child\nreset\n")
	for _, r := range lockRows {
		prog := "on_lock"
		if strings.HasPrefix(r, "unlock") {
			prog = "on_unlock"
		}
		fmt.Fprintf(&ks, "run %s %s\ndrain Edges\n", prog, r)
	}
	ks.WriteString("dump\n")
	kn := feed(t, true, ks.String(), h.kernelBin, mfixPath())
	var kl []string
	for _, l := range strings.Split(kn, "\n") {
		if strings.HasPrefix(l, "rv=") {
			addrs = append(addrs, strings.TrimPrefix(l, "rv="))
			continue
		}
		if strings.HasPrefix(l, "child=") {
			l = "ok"
		}
		kl = append(kl, l)
	}
	if len(addrs) != 4 {
		t.Fatalf("want 4 rv lines (the lock rows), got %v:\n%s", addrs, kn)
	}
	var ts strings.Builder
	ts.WriteString(childTask(t, kn) + "reset\n")
	i := 0
	for _, r := range lockRows {
		if strings.HasPrefix(r, "unlock") {
			fmt.Fprintf(&ts, "run on_unlock %s\ndrain Edges\n", r)
			continue
		}
		fmt.Fprintf(&ts, "run on_lock at %s\ndrain Edges\n", addrs[i])
		i++
	}
	ts.WriteString("dump\n")
	return strings.Join(kl, "\n"), feed(t, false, ts.String(), h.twinBin), addrs
}

// TestUprobePtrDifferential は H3 (root): 子の mfix の pid に attach した kernel の Edges・Held・Out が、子の答えの address を `at` に挟んだ双子と
// byte で同じ。辺はちょうど 2 つ (A→B と B→A — A・B は子の 2 つの mutex の address)、Out は 4 / 2 / 0、Held は最後に A。
func TestUprobePtrDifferential(t *testing.T) {
	requireUnverified(t)
	h := sysHarnesses(t, "up_libc_lock")
	kn, tw, addrs := lockDiff(t, h)
	if os.Getenv("E157_OUT") != "" {
		os.WriteFile(filepath.Join(os.Getenv("E157_OUT"), "lock.kernel.out"), []byte(kn), 0o644)
		os.WriteFile(filepath.Join(os.Getenv("E157_OUT"), "lock.twin.out"), []byte(tw), 0o644)
	}
	a, b := addrs[0], addrs[1]
	t.Logf("A=%s B=%s\n%s", a, b, kn)
	if addrs[2] != b || addrs[3] != a || a == b {
		t.Errorf("the child's addresses %v: want A, B, B, A with A != B", addrs)
	}
	bad := uprobeCompare(tw, kn)
	for _, x := range first(bad, 8) {
		t.Errorf("%s", x)
	}
	for _, w := range []string{"Edges#0.from=" + a + "\nEdges#0.to=" + b + "\n", "Edges#0.from=" + b + "\nEdges#0.to=" + a + "\n", "Out[0]=4\n", "Out[1]=2\n", "Out[2]=0\n", "=" + a + "\n"} {
		if !strings.Contains(kn, w) {
			t.Errorf("kernel: want %q", w)
		}
	}
	if strings.Count(kn, "Edges drained=1") != 2 {
		t.Errorf("kernel: want exactly 2 edge events")
	}
}

// TestBccSelftestDeadlock は H5 (root): --selftest (自分の pid だけに attach — 自分の 2 つの mutex を A・B・(離す)・B・A) で、自分の 2 つの address の
// 逆転の組がちょうど 1 つ。bccSelftest の実用の形 (--duration-ms — pid 0) は deadlock の口が受けない (--pid 必須) ので走らせない。
func TestBccSelftestDeadlock(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/deadlock")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "deadlock")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "selftest ok") || !strings.Contains(out, "own_inversions=1") {
		t.Errorf("--selftest: want %q and own_inversions=1", "selftest ok")
	}
}
