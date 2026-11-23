package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E112 の試験 (P026 — uretprobe の戻り値): 生成物 (H1)・Go の target の build の時の照合 (H2 (d))・双子の smoke (H3)・
// kernel と双子の 2 段の差動 (H4 — root)・照合を通さない Go の target の load (H5 — root)・attach の kind の取り違え (H6 — root)。
// 負の例 (H2 (a)〜(c)) は internal/frontend の testdata/uprobe/neg_uret_*.rb (TestUprobeNegative)。

// copyUprobeSrc は testdata/uprobe の source と target/ を一時の dir に写す (target は source の directory からの相対)。
func copyUprobeSrc(t *testing.T, name string) string {
	t.Helper()
	d := t.TempDir()
	b, _ := os.ReadFile(uprobeSrc(name))
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, b, 0o644)
	os.MkdirAll(filepath.Join(d, "target"), 0o755)
	cf, _ := os.ReadFile(cfixPath())
	writeExec(t, filepath.Join(d, "target", "cfix"), cf)
	return src
}

// TestUretprobeArtefacts は H1: .mlir の program の行と probe.retval (i64 と i32 + extui)、schema、ELF の requirements の版 9 と付随の行。
func TestUretprobeArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	src := copyUprobeSrc(t, "uret_ints")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	d := filepath.Dir(src)
	m, _ := os.ReadFile(filepath.Join(d, "uret_ints.mlir"))
	for _, w := range []string{`ebpf.program @on_sum_ret "uretprobe" attach "sum_args" arch "x86_64"`, `ebpf.probe.retval %ctx : !ebpf.ctx<"uretprobe"> -> i64`,
		`ebpf.program @on_greet_ret "uretprobe" attach "greet" arch "x86_64"`, `ebpf.probe.retval %ctx : !ebpf.ctx<"uretprobe"> -> i32`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	sums, _ := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", "target", "SHA256SUMS"))
	sha := strings.Fields(string(sums))[0]
	s, _ := os.ReadFile(filepath.Join(d, "uret_ints.schema.json"))
	if !strings.Contains(string(s), `"kind": "uretprobe"`) || !strings.Contains(string(s), `"binary_sha256": "`+sha+`"`) || !strings.Contains(string(s), `"arch": "x86_64"`) || strings.Contains(string(s), `"params"`) {
		t.Errorf("schema programs: want kind uretprobe, arch, binary_sha256 %s and no params:\n%s", sha, s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "uret_ints.bpf.o"))
	for _, w := range []string{"ebpf-requirements 9\n", "attach\ton_sum_ret\turetprobe\tsum_args\n", "ctxfield\ton_sum_ret\tpt_regs\tax\t80\t8\n", "binary\ton_sum_ret\tsha256\t" + sha + "\n",
		"attach\ton_greet_ret\turetprobe\tgreet\n", "arch\ton_greet_ret\tx86_64\n"} {
		if !strings.Contains(r, w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
	if strings.Contains(r, "uprobearg") {
		t.Errorf("a uretprobe has no uprobearg row:\n%s", r)
	}
}

// uretWatchSrc は Go の target の関数の uretprobe (H2 (d)・H5)。`<exe> <target> load` は load の結果だけ。
func uretWatchSrc(rel, sym string) string {
	return `require "bpf"

Rets = BPF::ArrayMap.new("Rets", :i64, 1)

def on_fn(ctx)
  Rets.update(0, ctx.ret)
end
BPF.uretprobe :on_fn, "` + rel + `", "` + sym + `", ret: :i64

require "spinelbpf"

tg = SpinelBPF::UprobeTargets.new
tg.add("on_fn", ARGV[0])
begin
  obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
  puts "load ok unmet=#{obj.unmet.length}"
  obj.close
rescue SpinelBPF::Error => e
  puts "load kind=#{e.class} msg=#{e.message}"
end
`
}

// uretWatchBuild は uretWatchSrc を Go の target で build する (force は照合を通さずに ELF・埋め込み・link — E082 の uwatchBuild の形)。
func uretWatchBuild(t *testing.T, target, rel, sym string, force bool) (string, error) {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := filepath.Join(d, "uwatch.rb")
	os.WriteFile(src, []byte(uretWatchSrc(rel, sym)), 0o644)
	b, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Dir(filepath.Join(d, rel)), 0o755)
	writeExec(t, filepath.Join(d, rel), b)
	exe := filepath.Join(d, "uwatch")
	if _, err := Build(cfg, src); err != nil {
		if !force {
			return exe, err
		}
		if err := runIn(d, cfg.EbpfCompile, "uwatch.mlir", "--schema", "uwatch.schema.json", "-o", "uwatch.bpf.o"); err != nil {
			t.Fatalf("forced compile: %v", err)
		}
		schema, _ := os.ReadFile(filepath.Join(d, "uwatch.schema.json"))
		sha, err := checkSchemaSHA(filepath.Join(d, "uwatch.bpf.o"), schema)
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, "uwatch_embed.S"), []byte(embedAsm("uwatch.bpf.o", sha, "uwatch.maps.json")), 0o644)
		if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "uwatch_embed.S", "-o", "uwatch_embed.o"); err != nil {
			t.Fatal(err)
		}
	} else if force {
		t.Fatalf("the Go target was expected to stop the build")
	}
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe, nil
}

// TestUretprobeGoTargetBuild は H2 (d): Go の関数の uretprobe は build の時の照合が SB032 で uretprobe_abi を名指す。
func TestUretprobeGoTargetBuild(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	_, err := uretWatchBuild(t, goFixture(t), "target/gofix", "main.Greet", false)
	t.Logf("build: %v", err)
	if msg := sb032(err); !strings.Contains(msg, "uretprobe_abi") {
		t.Errorf("want one SB032 naming uretprobe_abi, got %v", err)
	}
}

// TestUretprobeTwinSmoke は H3: 双子の ret=6・ret=-1 (sum) と ret=4294967295 (greet)。
func TestUretprobeTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, uprobeSrc("uret_ints"))
	out := feed(t, false, "reset\nrun on_sum_ret ret=6\nrun on_sum_ret ret=-1\nrun on_greet_ret ret=4294967295\ndump\n", h.twinBin)
	wantLines(t, out, "Rets[0]=-1", "Rets[1]=2", "Rets[2]=5", "Rets[3]=4294967295", "Rets[4]=1")
}

// uretRows は H4 の cfix の行 (program と命令)。
var uretRows = [][2]string{{"on_sum_ret", "sum 1 2 3"}, {"on_sum_ret", "sum -9223372036854775807 0 0"}, {"on_sum_ret", "sum 0 4294967295 0"},
	{"on_greet_ret", "greet 5 hello"}, {"on_greet_ret", "greet 4294967290 hello"}}

// uretDiff は 2 段の差動: kernel は子の cfix に命令を送り子の答えの値 (rv=) を出し、双子は同じ rv を ret= に。
func uretDiff(t *testing.T, h harnessSet) (kernel, twin string, rvs []string) {
	t.Helper()
	var ks strings.Builder
	ks.WriteString("child\nreset\n")
	for _, r := range uretRows {
		fmt.Fprintf(&ks, "run %s %s\n", r[0], r[1])
	}
	ks.WriteString("dump\n")
	kernel = feed(t, true, ks.String(), h.kernelBin, cfixPath())
	for _, l := range strings.Split(kernel, "\n") {
		if strings.HasPrefix(l, "rv=") {
			rvs = append(rvs, strings.TrimPrefix(l, "rv="))
		}
	}
	if len(rvs) != len(uretRows) {
		t.Fatalf("want %d rv lines, got %v:\n%s", len(uretRows), rvs, kernel)
	}
	var ts strings.Builder
	ts.WriteString("reset\n")
	for i, r := range uretRows {
		fmt.Fprintf(&ts, "run %s ret=%s\n", r[0], rvs[i])
	}
	ts.WriteString("dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestUretprobeDifferential は H4 (root): 子の pid に attach した kernel の dump が子の答えを挟んだ双子と一致し、回数は自分の run と厳密に一致。
func TestUretprobeDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, uprobeSrc("uret_ints"))
	k, w, rvs := uretDiff(t, h)
	t.Log(k)
	if strings.Join(rvs, " ") != "6 -9223372036854775807 4294967295 10 4294967295" {
		t.Errorf("the child's answers: %v", rvs)
	}
	sameDump(t, "uretprobe", k, w)
	for _, l := range []string{"Rets[0]=4294967295", "Rets[1]=3", "Rets[2]=-9223372032559808506", "Rets[3]=4294967295", "Rets[4]=2"} {
		if !strings.Contains(k, l+"\n") {
			t.Errorf("kernel: want %s", l)
		}
	}
}

// TestUretprobeGoTargetLoad は H5 (root): 照合を通さずに作った Go の target の ELF の load を bml の照合が uretprobe_abi (TargetRejected) で止める。
func TestUretprobeGoTargetLoad(t *testing.T) {
	requireUnverified(t)
	gofix := goFixture(t)
	exe, _ := uretWatchBuild(t, gofix, "target/gofix", "main.Greet", true)
	out := feed(t, true, "", exe, gofix)
	t.Log(out)
	// 追補 2 (E112): 例外は文だけを持ち kind の名前は出ない — bml の src/req/unmet.c の uretprobe_abi の固定の部分で見る
	// (uretprobe_abi_unknown の文は「…register; the binary's DWARF cannot confirm …」で一致しない)
	if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") || !strings.Contains(out, "from the SysV return value register, which that function does not use alone") {
		t.Errorf("want bml's pre-load check to stop the Go function with uretprobe_abi (TargetRejected and its fixed text), got\n%s", out)
	}
}

// TestUretprobeAttachKind は H6 (root): uretprobe を uprobe として・uprobe を uretprobe として attach すると誤り、正しい kind は OK。
func TestUretprobeAttachKind(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "uprobe", "uret_attach_kind.rb"))
	src := filepath.Join(d, "uret_attach_kind.rb")
	os.WriteFile(src, b, 0o644)
	cf, _ := os.ReadFile(cfixPath())
	os.MkdirAll(filepath.Join(d, "target"), 0o755)
	writeExec(t, filepath.Join(d, "target", "cfix"), cf)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "uret_attach_kind")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, filepath.Join(d, "target", "cfix"))
	t.Log(out)
	for _, w := range []string{"uretprobe as uretprobe kind=OK", "detached"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "uretprobe as uprobe kind=SpinelBPF::") || !strings.Contains(out, "uprobe as uretprobe kind=SpinelBPF::") {
		t.Errorf("attaching across uprobe / uretprobe must fail loudly")
	}
}
