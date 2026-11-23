package main

import (
	"bytes"
	"debug/elf"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E005 の試験: 同じ source の native の twin との差動 (model は同じ source の native の実行 — CLAUDE.md)・twin の型・対照の .mlir・差動の変異の対照。
// VM (virtme-ng) の段は SPINELBPF_VM=1 のときだけ (時間がかかる — E005 の記録は scripts/run-xdpcount-vm.sh の出力)。

// twin は example の source の native の twin を build して n 回走らせた出力と、注入の解析の結果を返す。
func twin(t *testing.T, src string, n int) (string, *frontend.Result, string) {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	work := t.TempDir()
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, work, src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := frontend.NativeTwin(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	base := filepath.Base(src)
	os.WriteFile(filepath.Join(dir, base), []byte(tw), 0o644)
	bin := filepath.Join(dir, "twin")
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), base, "-o", bin)
	c.Dir = dir
	c.Env = append(os.Environ(), "TMPDIR="+dir)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin: %v\n%s", err, o)
	}
	out, err := exec.Command(bin, fmt.Sprint(n)).CombinedOutput()
	if err != nil {
		t.Fatalf("running the twin: %v\n%s", err, out)
	}
	return string(out), res, work
}

var (
	bpfCount  = regexp.MustCompile(`counts\[(\d+)\]=(\d+)`)
	twinCount = regexp.MustCompile(`twin Counts\[(\d+)\]=(\d+)`)
	bpfRet    = regexp.MustCompile(`selftest: ret=(\d+)`)
)

// diffRows は差動の表 (P001 §3.8 — map の op の行): 各 slot の値と、戻り値が全て XDP_PASS か。不一致の行を返す。
func diffRows(bpf, tw string) (rows []string, bad []string) {
	// BPF の値は `selftest: ret=… counts[k]=v …` の行だけから読む (自己の検査の失敗の文言 `(want … counts[0]=counts[1]=50)` にも
	// `counts[1]=50` が現れる — E005 の 1 回目はそれを拾って本当の値を上書きし、変異の Counts[1] の不一致を見逃した)
	b := map[string]string{}
	for _, l := range strings.Split(bpf, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "selftest: ret=") {
			continue
		}
		for _, m := range bpfCount.FindAllStringSubmatch(l, -1) {
			b[m[1]] = m[2]
		}
	}
	w := map[string]string{}
	for _, m := range twinCount.FindAllStringSubmatch(tw, -1) {
		w[m[1]] = m[2]
	}
	var keys []string
	for k := range w {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		r := fmt.Sprintf("Counts[%s]: bpf=%s twin=%s", k, b[k], w[k])
		rows = append(rows, r)
		if b[k] != w[k] {
			bad = append(bad, r)
		}
	}
	ret := bpfRet.FindStringSubmatch(bpf)
	r := fmt.Sprintf("verdict: bpf ret=%v twin not_XDP_PASS=%v", ret, strings.Contains(tw, "not_XDP_PASS=0"))
	rows = append(rows, r)
	if ret == nil || ret[1] != "2" || !strings.Contains(tw, "not_XDP_PASS=0") {
		bad = append(bad, r)
	}
	if len(w) == 0 {
		bad = append(bad, "the twin printed no map values")
	}
	return rows, bad
}

// TestDifferential は E005 の H3: host 7.1.8 (root) の selftest 50 回と twin 50 回の表が一致 (SPINELBPF_VM=1 なら 2 つの VM も)。
func TestDifferential(t *testing.T) {
	parallel(t) // P018 E075
	exe := linkedExample(t)
	tw, _, _ := twin(t, filepath.Join(repoRoot(), "examples", "xdpcount", "xdpcount.rb"), 50)
	targets := map[string]string{}
	out, err := sudo(t, exe, "--selftest", "50")
	if err != nil {
		t.Fatalf("host selftest: %v\n%s", err, out)
	}
	targets["host "+uname(t)] = out
	if os.Getenv("SPINELBPF_VM") == "1" {
		for _, k := range []string{"6.12.111", "6.6.157"} {
			img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
			o, err := sudo(t, filepath.Join(repoRoot(), "scripts", "run-xdpcount-vm.sh"), img, exe, "50")
			if err != nil {
				t.Fatalf("vm %s: %v\n%s", k, err, o)
			}
			targets["vm "+k] = o
		}
	}
	for name, o := range targets {
		rows, bad := diffRows(o, tw)
		t.Logf("%s:\n  %s", name, strings.Join(rows, "\n  "))
		if len(bad) > 0 {
			t.Errorf("%s: mismatching rows: %v", name, bad)
		}
	}
}

func uname(t *testing.T) string {
	o, _ := exec.Command("uname", "-r").Output()
	return strings.TrimSpace(string(o))
}

// TestTwinTypes は E005 の H4: twin の build の root の def の範囲の型の record が、注入の解析 (typing) と一致する。
func TestTwinTypes(t *testing.T) {
	parallel(t) // P018 E075
	src := filepath.Join(repoRoot(), "examples", "xdpcount", "xdpcount.rb")
	_, res, work := twin(t, src, 1)
	cfg, _ := defaultConfig()
	text, _ := os.ReadFile(src)
	tw, _ := frontend.NativeTwin(string(text), res)
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "xdpcount.rb"), []byte(tw), 0o644)
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), "--emit-types", "xdpcount.rb", "-o", filepath.Join(dir, "twin.json"))
	c.Dir = dir
	c.Env = append(os.Environ(), "TMPDIR="+dir)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, o)
	}
	load := func(p string) *frontend.Types {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		ty, err := frontend.ParseTypes(b)
		if err != nil {
			t.Fatal(err)
		}
		return ty
	}
	tt, wt := load(filepath.Join(work, "typing", "types.json")), load(filepath.Join(dir, "twin.json"))
	p := res.Programs[0]
	pick := func(ty *frontend.Types) []string {
		var out []string
		for _, r := range ty.Types {
			if r.File == "xdpcount.rb" && r.Line >= p.Pos.Line && r.EndLine <= p.EndLine {
				out = append(out, fmt.Sprintf("%d:%d-%d:%d %s %s %s %s", r.Line, r.Col, r.EndLine, r.EndCol, r.Kind, r.Name, r.RBS, r.Signature))
			}
		}
		sort.Strings(out)
		return out
	}
	a, b := pick(tt), pick(wt)
	if len(a) == 0 || strings.Join(a, "\n") != strings.Join(b, "\n") {
		t.Fatalf("the twin's types differ from the typing probe's\n--- typing\n%s\n--- twin\n%s", strings.Join(a, "\n"), strings.Join(b, "\n"))
	}
	t.Logf("%d records in count_pkts agree", len(a))
}

// TestControlMLIR は E005 の H5: 手で書いた対照の .mlir の ELF の xdp の section が例の ELF と byte 一致、--line-info=off の例の ELF とは全体が一致。
func TestControlMLIR(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	dir := t.TempDir()
	ex := filepath.Join(repoRoot(), "examples", "xdpcount")
	for _, f := range []string{"xdpcount.mlir", "xdpcount.schema.json"} {
		b, _ := os.ReadFile(filepath.Join(ex, f))
		os.WriteFile(filepath.Join(dir, f), b, 0o644)
	}
	ctl, _ := os.ReadFile(filepath.Join("testdata", "control_xdpcount.mlir"))
	os.WriteFile(filepath.Join(dir, "control.mlir"), ctl, 0o644)
	for _, args := range [][]string{
		{"control.mlir", "--schema", "xdpcount.schema.json", "-o", "control.bpf.o"},
		{"xdpcount.mlir", "--schema", "xdpcount.schema.json", "--line-info=off", "-o", "off.bpf.o"},
	} {
		if err := runIn(dir, cfg.EbpfCompile, args...); err != nil {
			t.Fatal(err)
		}
	}
	sec := func(p string) []byte {
		f, err := elf.Open(p)
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		b, err := f.Section("xdp").Data()
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	if !bytes.Equal(sec(filepath.Join(dir, "control.bpf.o")), sec(filepath.Join(ex, "xdpcount.bpf.o"))) {
		t.Fatal("the control's xdp section differs from the example's")
	}
	a, _ := os.ReadFile(filepath.Join(dir, "control.bpf.o"))
	b, _ := os.ReadFile(filepath.Join(dir, "off.bpf.o"))
	t.Logf("whole ELF: control %d bytes, example --line-info=off %d bytes, equal=%v", len(a), len(b), bytes.Equal(a, b))
	if !bytes.Equal(a, b) {
		t.Error("the control's ELF differs from the example compiled with --line-info=off")
	}
}

// TestDifferentialMutation は E005 の H6: 生成の .mlir の atomic_add の delta を 1 → 2 にした実行 file が受理され、selftest の自己の検査が
// FAILED で止まり、twin との差動が Counts[0] と Counts[1] の 2 行を不一致と報告する (意図した理由 — lowering の値の誤り)。
func TestDifferentialMutation(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e005mut-")
	if err != nil {
		t.Fatal(err)
	}
	src := copyExample(t, d)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "xdpcount.mlir"))
	orig := `%v1 = arith.constant 1 : i64`
	if strings.Count(string(m), orig) != 1 {
		t.Fatalf("the atomic_add delta constant was not found exactly once:\n%s", m)
	}
	os.WriteFile(filepath.Join(d, "xdpcount.mlir"), []byte(strings.Replace(string(m), orig, `%v1 = arith.constant 2 : i64`, 1)), 0o644)
	if err := runIn(d, cfg.EbpfCompile, "xdpcount.mlir", "--schema", "xdpcount.schema.json", "-o", "xdpcount.bpf.o"); err != nil {
		t.Fatal(err)
	}
	sha, err := checkSchemaSHA(filepath.Join(d, "xdpcount.bpf.o"), r.Output.Schema)
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(d, "xdpcount_embed.S"), []byte(embedAsm("xdpcount.bpf.o", sha, "xdpcount.maps.json")), 0o644)
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "xdpcount_embed.S", "-o", "xdpcount_embed.o"); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "xdpcount_mut")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out, err := sudo(t, exe, "--selftest", "50")
	if err == nil || !strings.Contains(out, "selftest FAILED") || !strings.Contains(out, "counts[0]=100 counts[1]=100") {
		t.Fatalf("want the mutant accepted and its self-check failed with counts 100/100, got err=%v\n%s", err, out)
	}
	tw, _, _ := twin(t, src, 50)
	rows, bad := diffRows(out, tw)
	t.Logf("mutant:\n  %s", strings.Join(rows, "\n  "))
	if len(bad) != 2 || !strings.HasPrefix(bad[0], "Counts[0]") || !strings.HasPrefix(bad[1], "Counts[1]") {
		t.Fatalf("want exactly the two Counts rows to mismatch, got %v", bad)
	}
}
