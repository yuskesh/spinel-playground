package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E052 の試験 (P013): tracing の双子の harness (合成の context) の smoke — 差動ではない (kernel の側は E053)。手の期待は harness が動くことの確かめだけ。

// twinOnly は source の双子の harness だけを build する (kernel の harness は tracing では E053)。
func twinOnly(t *testing.T, name string) (string, *frontend.Result) {
	t.Helper()
	cfg, _ := defaultConfig()
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb")
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
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, name+".rb"), []byte(tw), 0o644)
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), name+".rb", "-o", "twin")
	c.Dir, c.Env = d, append(os.Environ(), "TMPDIR="+d)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s\n%s", err, o, tw)
	}
	return filepath.Join(d, "twin"), res
}

func wantLines(t *testing.T, out string, wants ...string) {
	t.Helper()
	for _, w := range wants {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q in:\n%s", w, out)
		}
	}
}

// TestTracingTwinSmoke は E052 の H2〜H4: 3 つの正の例の双子の harness が build でき、合成の context の幅 (u32 の mask・i32 の符号の拡張) と濾しが効く。
func TestTracingTwinSmoke(t *testing.T) {
	parallel(t)                         // P018 E075
	requireUnverified(t)                // E046: 入力の鍵が verified.tsv に在れば skip
	tg, tid := "4242", "18219251273881" // tgid 4242 << 32 | tid 4249
	tgOther := "18223546241177"         // tgid 4243 << 32 | tid 4249
	fx, _ := twinOnly(t, "trace_fexit")
	out := feed(t, false, "reset\npoke Filter 0 "+tg+"\ntask "+tid+"\nrun on_ret ret=0\nrun on_ret ret=5\nrun on_ret ret=-1\ntask "+tgOther+"\nrun on_ret ret=5\ndump\n", fx)
	wantLines(t, out, "ret=0", "Rets[0]=1", "Rets[1]=1", "Rets[2]=1")
	out = feed(t, false, "reset\npoke Filter 0 "+tg+"\ntask "+tid+"\nrun on_ret ret=4294967295\ndump\nrun on_ret a2=1\n", fx)
	wantLines(t, out, "Rets[2]=1", "err=RuntimeError") // H3: ret :i32 に 2^32 − 1 → −1 (負の側)。宣言に無い a2 は誤り
	kp, _ := twinOnly(t, "trace_kprobe")
	out = feed(t, false, "reset\npoke Filter 0 "+tg+"\ntask "+tid+"\nrun on_poll a2=3\nrun on_poll a2=4\nrun on_poll a2=4294967303\ndump\n", kp)
	wantLines(t, out, "Sums{4242}=14") // 3 + 4 + (2^32 + 7 を u32 で 7) — H3・H4
	fe, _ := twinOnly(t, "trace_fentry")
	out = feed(t, false, "reset\npoke Filter 0 "+tg+"\ntask "+tid+"\nrun on_test1\nrun on_test1\ntask "+tgOther+"\nrun on_test1\ndump\n", fe)
	wantLines(t, out, "Calls{4242}=2")
	if strings.Contains(out, "Calls{4243}") {
		t.Errorf("the filter let another tgid through:\n%s", out)
	}
}

// TestTracingHarnessStops は E052 の H5 (E053 で改めた): NativeTwin は tracing の program で E053 を名指しで止まる。KernelHarness は E053 で tracing を作れるようになった。
func TestTracingHarnessStops(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_fexit.rb")
	text, _ := os.ReadFile(src)
	res, err := frontend.Analyze(frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}, t.TempDir(), src, string(text))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := frontend.KernelHarness(string(text), res); err != nil {
		t.Errorf("KernelHarness: E053 builds the tracing kernel harness, got %v", err)
	}
	if _, err := frontend.NativeTwin(string(text), res); err == nil || !strings.Contains(err.Error(), "is not written (it needs the C loader's tracing attach and test run)") {
		t.Errorf("NativeTwin: want the named tracing stop, got %v", err)
	}
}
