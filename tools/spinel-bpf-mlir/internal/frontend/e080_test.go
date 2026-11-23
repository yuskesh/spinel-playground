package frontend

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/go-bpf-mlir/requirements"
)

// E080 の試験 (P020): uprobe の負の例 (testdata/uprobe/neg_*.rb — target/cfix を相対で指すので neg/ に置けない) と build の時の照合の種類の分け。

// TestUprobeNegative は E080 の H5: uprobe の負の例が want の code と位置で、1 つの止める診断で止まる (TestNegative と同じ検査)。
func TestUprobeNegative(t *testing.T) {
	sp := testSpinel(t)
	files, _ := filepath.Glob(filepath.Join("testdata", "uprobe", "neg_*.rb"))
	if len(files) < 10 {
		t.Fatalf("expected the uprobe negative corpus, found %d files", len(files))
	}
	for _, f := range files {
		f := f
		t.Run(strings.TrimSuffix(filepath.Base(f), ".rb"), func(t *testing.T) { checkNegative(t, sp, f) })
	}
}

// TestUprobeBuildKindsClassified は E080 の H3: build の時の照合の種類の分け — 止める 14 (uprobe の 7 と E107 の 5 と E156 の 2) と無視の 86 (E165 で 58 → 86) は重ならず、合わせて bpf-mlir の UnmetKinds に
// ちょうど等しい (bpf-mlir が種類を足したら落ちる — 足した種類は UprobeBuildCheck でも fail closed で止まる)。
func TestUprobeBuildKindsClassified(t *testing.T) {
	all := map[string]bool{}
	for _, k := range requirements.UnmetKinds {
		all[k.Kind] = true
	}
	for k := range UprobeBuildKinds {
		if UprobeBuildIgnored[k] {
			t.Errorf("%s is both stopped and ignored", k)
		}
		if !all[k] {
			t.Errorf("%s (stopped) is not a bpf-mlir Unmet kind", k)
		}
	}
	for k := range UprobeBuildIgnored {
		if !all[k] {
			t.Errorf("%s (ignored) is not a bpf-mlir Unmet kind", k)
		}
	}
	for k := range all {
		if !UprobeBuildKinds[k] && !UprobeBuildIgnored[k] {
			t.Errorf("bpf-mlir's Unmet kind %s is not classified", k)
		}
	}
	if len(UprobeBuildKinds) != 14 || len(UprobeBuildIgnored) != 86 || len(all) != 100 {
		t.Errorf("counts: stopped %d, ignored %d, bpf-mlir %d (want 14 / 86 / 100 — bpf-mlir e0a98646d)", len(UprobeBuildKinds), len(UprobeBuildIgnored), len(all))
	}
}

// TestUprobePositive は E080 の H2 と H3 (正しい例): up_ints / up_str が生成でき bpf-mlir の道具を通り、build の時の照合の Unmet 0。schema の
// binary_sha256 は fixture の SHA-256 = SHA256SUMS の行、path の文字列は .mlir・schema・maps.json・ELF に無い、ELF の requirements に binary と uprobearg。
func TestUprobePositive(t *testing.T) {
	sp := testSpinel(t)
	sums, err := os.ReadFile(filepath.Join("testdata", "uprobe", "target", "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Fields(string(sums))[0]
	bin, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "target", "cfix"))
	if got := fmt.Sprintf("%x", sha256.Sum256(bin)); got != want {
		t.Fatalf("the committed fixture's SHA-256 %s differs from SHA256SUMS %s", got, want)
	}
	for _, c := range []struct{ name, mlir, req string }{
		{"up_ints", `ebpf.uprobe.arg %ctx 3 : !ebpf.ctx<"uprobe"> -> i32`, "uprobearg\ton_sum\t3\ti32\n"},
		{"up_str", `ebpf.user.read_str`, "uprobearg\ton_greet\t1\tstrptr\n"},
	} {
		out, err := Generate(sp, t.TempDir(), filepath.Join("testdata", "uprobe", c.name+".rb"))
		if err != nil {
			t.Fatalf("%s: generate: %v", c.name, err)
		}
		elf := compileAll(t, out)
		if err := UprobeBuildCheck(elf, out.Result); err != nil {
			t.Errorf("%s: the build-time check refused a correct program: %v", c.name, err)
		}
		if !strings.Contains(out.MLIR, c.mlir) || !strings.Contains(out.MLIR, `"uprobe" attach `) || !strings.Contains(out.MLIR, `arch "x86_64"`) {
			t.Errorf("%s: the .mlir lacks %q or the uprobe program header", c.name, c.mlir)
		}
		if !strings.Contains(string(out.Schema), `"binary_sha256": "`+want+`"`) {
			t.Errorf("%s: schema binary_sha256 is not the fixture's %s", c.name, want)
		}
		for what, b := range map[string][]byte{"mlir": []byte(out.MLIR), "schema": out.Schema, "maps": out.Maps, "elf": elf} {
			if bytes.Contains(b, []byte("target/cfix")) || bytes.Contains(b, []byte("cfix")) {
				t.Errorf("%s: the %s contains the target path", c.name, what)
			}
		}
		if !bytes.Contains(elf, []byte("binary\ton_")) || !bytes.Contains(elf, []byte(c.req)) || !bytes.Contains(elf, []byte(want)) {
			t.Errorf("%s: the ELF requirements lack the binary / uprobearg rows (%q)", c.name, c.req)
		}
	}
}

// TestUprobeBuildMismatch は E080 の H3 (食い違い): 引数の型 (u32 を :i64・i32 を :u32) は uprobearg、無い symbol は uprobe_symbol で、宣言の位置の
// SB032 の 1 つの診断で止まる。
func TestUprobeBuildMismatch(t *testing.T) {
	sp := testSpinel(t)
	src, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "up_ints.rb"))
	for _, c := range []struct{ name, from, to, kind string }{
		{"type", "2 => :u32", "2 => :i64", "uprobearg 2 of sum_args"},
		{"sign", "3 => :i32", "3 => :u32", "uprobearg 3 of sum_args"},
		{"symbol", `"sum_args"`, `"no_such_fn"`, "uprobe_symbol no_such_fn"},
	} {
		d := t.TempDir()
		os.MkdirAll(filepath.Join(d, "target"), 0o755)
		b, _ := os.ReadFile(filepath.Join("testdata", "uprobe", "target", "cfix"))
		os.WriteFile(filepath.Join(d, "target", "cfix"), b, 0o644)
		f := filepath.Join(d, "up_ints.rb")
		os.WriteFile(f, []byte(strings.Replace(string(src), c.from, c.to, 1)), 0o644)
		out, err := Generate(sp, t.TempDir(), f)
		if err != nil {
			t.Fatalf("%s: generate: %v", c.name, err)
		}
		err = UprobeBuildCheck(compileAll(t, out), out.Result)
		var e *Error
		if !errors.As(err, &e) || len(e.Diags) != 1 || e.Diags[0].Code != SB032UprobeTarget || e.Diags[0].Pos.Line != 11 || !strings.Contains(e.Diags[0].Msg, c.kind) {
			t.Errorf("%s: want one SB032 at the declaration (line 11) naming %q, got %v", c.name, c.kind, err)
			continue
		}
		t.Logf("%s: %s", c.name, e.Diags[0])
	}
}

// TestUprobeHarnessStops は E080 の H6 を E081 で改めた形: TwinHarness・KernelHarness は uprobe の形 (双子の UprobeCtx・kernel の子の process と
// load の引数の target) を作り、Thread の変種と E005 の NativeTwin は名指し (E081) で止まる。
func TestUprobeHarnessStops(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "uprobe", "up_str.rb")
	text, _ := os.ReadFile(f)
	res, err := Analyze(sp, t.TempDir(), f, string(text))
	if err != nil || len(res.Programs) == 0 {
		t.Fatalf("analyze: %v", err)
	}
	for what, gen := range map[string]func(string, *Result) (string, error){
		"NativeTwin": NativeTwin, "TwinHarnessThreads": TwinHarnessThreads, "KernelHarnessThreads": KernelHarnessThreads,
	} {
		if _, err := gen(string(text), res); err == nil || !strings.Contains(err.Error(), "uprobe") || !strings.Contains(err.Error(), "are not written here") {
			t.Errorf("%s: want the named uprobe stop, got %v", what, err)
		}
	}
	tw, err := TwinHarness(string(text), res)
	if err != nil || !strings.Contains(tw, "on_greet(BPF::UprobeCtx.new(_h_args, _h_strs, _h_bufs))") {
		t.Errorf("TwinHarness: want the uprobe form, got err %v", err)
	}
	kh, err := KernelHarness(string(text), res)
	if err != nil || !strings.Contains(kh, "SpinelBPF.load_embedded_targets(") || !strings.Contains(kh, `_h_obj.attach_uprobe("on_greet", HUprobe.h_pid)`) {
		t.Errorf("KernelHarness: want the uprobe form, got err %v", err)
	}
}

// TestUprobeFixtureRebuild は E080 の H4: scripts/build-uprobe-fixtures.sh --check (別の directory の再 build が commit の binary と byte 同じ)。
func TestUprobeFixtureRebuild(t *testing.T) {
	o, err := exec.Command(filepath.Join(repoRoot(t), "scripts", "build-uprobe-fixtures.sh"), "--check").CombinedOutput()
	if err != nil || !strings.Contains(string(o), "byte-identical") {
		t.Fatalf("fixture rebuild: %v\n%s", err, o)
	}
}
