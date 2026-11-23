package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E009 の試験: twin と kernel の同じ手順の harness・map_put・:i64 の −2^63 の ValueRange・CRuby の twin。

// harnesses は source から twin の harness (Spinel の native の実行 file と text) と kernel の harness (1 つの実行 file) を作る。
type harnessSet struct {
	twinBin, twinSrc, kernelBin string
}

func buildHarnesses(t *testing.T, src string) harnessSet {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	base := filepath.Base(src)
	// twin
	tw, err := frontend.TwinHarness(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	td := t.TempDir()
	twinSrc := filepath.Join(td, base)
	os.WriteFile(twinSrc, []byte(tw), 0o644)
	twinBin := filepath.Join(td, "twin")
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), base, "-o", twinBin)
	c.Dir, c.Env = td, append(os.Environ(), "TMPDIR="+td)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s\n%s", err, o, tw)
	}
	return harnessSet{twinBin: twinBin, twinSrc: twinSrc, kernelBin: buildKernelHarness(t, cfg, base, string(text), res, filepath.Dir(src))}
}

// buildKernelHarness は kernel の harness (照合付きの load をして手順を話す 1 つの実行 file) を作る。
func buildKernelHarness(t *testing.T, cfg Config, base, text string, res *frontend.Result, srcDir ...string) string {
	t.Helper()
	kh, err := frontend.KernelHarness(text, res)
	if err != nil {
		t.Fatal(err)
	}
	kd, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e009-")
	if err != nil {
		t.Fatal(err)
	}
	ksrc := filepath.Join(kd, base)
	// P020 E081: uprobe の target (宣言の source の directory からの相対の path) を harness の source の隣に同じ相対で写す (build が SHA-256 を読む)
	for _, p := range res.Programs {
		if (p.Kind != "uprobe" && p.Kind != "uretprobe") || len(srcDir) == 0 { // E112: uretprobe も
			continue
		}
		rel, err := filepath.Rel(srcDir[0], p.BinaryPath)
		if err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(p.BinaryPath)
		if err != nil {
			t.Fatal(err)
		}
		os.MkdirAll(filepath.Dir(filepath.Join(kd, rel)), 0o755)
		writeExec(t, filepath.Join(kd, rel), b)
	}
	os.WriteFile(ksrc, []byte(kh), 0o644)
	if _, err := Build(cfg, ksrc); err != nil {
		t.Fatalf("building the kernel harness: %v\n%s", err, kh)
	}
	kbin := filepath.Join(kd, "kernel")
	if err := Link(cfg, ksrc, kbin); err != nil {
		t.Fatal(err)
	}
	return kbin
}

// crubyFeed は CRuby の双子の harness の出力 — **SPINELBPF_CRUBY=1 のときだけ CRuby を走らせる** (利用者の決定 2026-09-27: CRuby の差動は一時的に外す —
// 再開は利用者の判断。gate と VM の表の run からは外れる)。外している時は Spinel の双子の出力を返し、CRuby との比べを自明に通す (差動は双子 (Spinel) = kernel の 2 者)。
func crubyFeed(t *testing.T, script string, h harnessSet) string {
	t.Helper()
	if os.Getenv("SPINELBPF_CRUBY") != "1" {
		return feed(t, false, script, h.twinBin)
	}
	return feed(t, false, script, "ruby", "-I", filepath.Join(repoRoot(), "ruby", "lib", "native"), h.twinSrc)
}

// feed は harness に命令を stdin で渡し、出力を返す (root は sudo)。
func feed(t *testing.T, root bool, script string, bin ...string) string {
	t.Helper()
	var cmd *exec.Cmd
	if root {
		if os.Getenv("SPINELBPF_NO_ROOT") == "1" {
			t.Skip("SPINELBPF_NO_ROOT=1")
		}
		cmd = sudoCmd(t, bin...)
	} else {
		cmd = exec.Command(bin[0], bin[1:]...)
	}
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %v\n%s", bin, err, out)
	}
	return string(out)
}

// TestHarnessAgree は E009 の H3・H4: ops_int (i32 の入力の 16 の演算) で、5 つの入力の twin・kernel (root)・CRuby の dump が全て一致。
func TestHarnessAgree(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "ops_int.rb")
	h := buildHarnesses(t, src)
	var script strings.Builder
	for _, v := range []string{"-7", "0", "1", "2147483647", "-2147483648"} {
		script.WriteString("reset\npoke In 0 " + v + "\nrun prog\ndump\n")
	}
	tw := feed(t, false, script.String(), h.twinBin)
	kn := feed(t, true, script.String(), h.kernelBin)
	rb := crubyFeed(t, script.String(), h)
	// kernel の harness は load の時の unmet の行を出さない — 手順の出力だけを比べる
	if tw != kn {
		t.Fatalf("twin and kernel differ\n--- twin\n%s\n--- kernel\n%s", tw, kn)
	}
	if tw != rb {
		t.Fatalf("Spinel twin and CRuby differ\n--- spinel\n%s\n--- cruby\n%s", tw, rb)
	}
	if strings.Contains(tw, "err=") || strings.Count(tw, "Out[") != 5*16 {
		t.Fatalf("unexpected harness output:\n%s", tw)
	}
	t.Logf("%d lines agree (twin = kernel = CRuby)", strings.Count(tw, "\n"))
}

// TestMapPut は E009 の H1 (root): map_put の書き込みと読み戻し、値の型の範囲の外・INT64_MIN (Spinel の to_i が返す nil の印) の ValueRange。
func TestMapPut(t *testing.T) {
	parallel(t) // P018 E075
	src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "ops_types.rb")
	h := buildHarnesses(t, src)
	script := "reset\n" +
		"poke U32 2 4294967295\npoke I32 2 -2147483648\npoke U64 2 9223372036854775807\npoke I64 1 -9223372036854775807\ndump\n" +
		"poke U32 0 -1\npoke U32 0 4294967296\npoke I32 0 2147483648\npoke U64 0 -1\npoke I64 0 -9223372036854775808\n"
	out := feed(t, true, script, h.kernelBin)
	for _, want := range []string{"U32[2]=4294967295", "I32[2]=-2147483648", "U64[2]=9223372036854775807", "I64[1]=-9223372036854775807"} {
		if !strings.Contains(out, want) {
			t.Errorf("want %q in\n%s", want, out)
		}
	}
	// INT64_MIN は Spinel の to_i が RangeError で止め loader まで届かない (E009 の 1 回目の観察 — loader の拒否は TestPutRange で)
	if n := strings.Count(out, "err=SpinelBPF::ValueRange"); n != 4 || !strings.Contains(out, "err=RangeError") {
		t.Errorf("want 4 ValueRange (u32 -1, u32 2^32, i32 2^31, u64 -1) and Spinel RangeError for the INT64_MIN literal, got %d\n%s", n, out)
	}
}

// TestI64MinValueRange は E009 の H2 (root — E003 のレビューの P3): eBPF の側が :i64 の map に −2^63 を書き、user 空間の map_get が ValueRange。
// −2^63+1 は OK で値が戻る。
func TestI64MinValueRange(t *testing.T) {
	parallel(t) // P018 E075
	d := t.TempDir()
	src := filepath.Join(d, "i64min.rb")
	os.WriteFile(src, []byte(`require "bpf"

I64 = BPF::ArrayMap.new("I64", :i64, 2)

def prog(ctx)
  I64.update(0, -9223372036854775807 - 1)
  I64.update(1, -9223372036854775807)
  BPF::XDP_PASS
end
BPF.xdp :prog
`), 0o644)
	h := buildHarnesses(t, src)
	out := feed(t, true, "reset\nrun prog\ndump\n", h.kernelBin)
	if !strings.Contains(out, "ret=2") || !strings.Contains(out, "I64[0]=err=SpinelBPF::ValueRange") || !strings.Contains(out, "I64[1]=-9223372036854775807") {
		t.Fatalf("want ret=2, I64[0] ValueRange and I64[1]=-9223372036854775807, got\n%s", out)
	}
}
