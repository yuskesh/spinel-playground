package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E013 の試験: ebpf-compile の rc 0 の warning を Ruby の位置付きの Conditional (SB021) に (P003 §2)。

func sb021(ds frontend.Diags) frontend.Diags {
	var r frontend.Diags
	for _, d := range ds {
		if d.Code == frontend.SB021CompileWarning {
			r = append(r, d)
		}
	}
	return r
}

// idxInput は bpf-mlir の kernel/nonroot/idx/idx_const.mlir (loc の無い入力 — 位置は file の名前から) の 2 つの op に
// frontend の形の loc を明示して dir に idx.mlir と idx.schema.json を置く: 12 行目の定数 (note の出どころ) と 19 行目の ref.index (region の閉じの 27 行目の後)。
// 行と列は元の file の位置と同じ (ebpf-compile の警告が元の file で指す 19:11 と 12:10)。
func idxInput(t *testing.T, dir string) {
	t.Helper()
	src := filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "bpfmlir", "nonroot_idx") // E161 追補 2: bpf-mlir の写し (PROVENANCE)
	b, err := os.ReadFile(filepath.Join(src, "idx_const.mlir"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(b), "\n")
	if !strings.Contains(lines[11], "%z = arith.constant 0 : i64") || !strings.Contains(lines[18], "%v0 = ebpf.ref.index") || strings.TrimSpace(lines[26]) != "}" {
		t.Fatalf("idx_const.mlir changed shape:\n%s", b)
	}
	lines[11] += ` loc("idx.rb":12:10)`
	lines[26] += ` loc("idx.rb":19:11)`
	os.WriteFile(filepath.Join(dir, "idx.mlir"), []byte(strings.Join(lines, "\n")), 0o644)
	s, err := os.ReadFile(filepath.Join(src, "schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "idx.schema.json"), s, 0o644)
}

// TestCompileWarningEndToEnd は E013 の H2: idx_const の形を build と同じ compile の関数に通すと rc 0・SB021 が 1 つ (19:11、note 12:10)・
// ELF は --warn-nonroot-index=false と byte 同じ・stderr の原文は相対の loc のまま。
func TestCompileWarningEndToEnd(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	idxInput(t, d)
	stderr, err := compileELF(cfg, d, "idx")
	if err != nil {
		t.Fatalf("want rc 0, got %v", err)
	}
	if !strings.HasPrefix(stderr, `loc("idx.rb":19:11): warning: the index of ebpf.ref.index can be a constant`) || !strings.Contains(stderr, `loc("idx.rb":12:10): note: the constant index comes from here`) {
		t.Fatalf("unexpected stderr:\n%s", stderr)
	}
	out := &frontend.Output{Result: &frontend.Result{}}
	if err := addCompileWarnings(out, "", stderr); err != nil {
		t.Fatal(err)
	}
	ws := sb021(out.Result.Diags)
	if len(ws) != 1 || out.Result.Diags.Blocking() {
		t.Fatalf("want one non-blocking SB021, got %v", out.Result.Diags)
	}
	w := ws[0]
	s := w.String()
	if w.Verdict != frontend.Conditional || w.Pos.String() != "idx.rb:19:11" ||
		!strings.Contains(s, "(note at idx.rb:12:10: the constant index comes from here)") ||
		!strings.Contains(s, "conditional SB021 (CompileWarning): ebpf-compile: the index of ebpf.ref.index") {
		t.Fatalf("unexpected SB021: %s", s)
	}
	t.Logf("%s", s)
	// ELF は warning の有無で変わらない
	c := exec.Command(cfg.EbpfCompile, "idx.mlir", "--schema", "idx.schema.json", "--line-info="+cfg.LineInfo, "--warn-nonroot-index=false", "-o", "idx0.bpf.o")
	c.Dir = d
	if o, err := c.CombinedOutput(); err != nil || len(o) != 0 {
		t.Fatalf("=false: %v %q", err, o)
	}
	a, _ := os.ReadFile(filepath.Join(d, "idx.bpf.o"))
	b, _ := os.ReadFile(filepath.Join(d, "idx0.bpf.o"))
	if len(a) == 0 || !bytes.Equal(a, b) {
		t.Fatalf("the ELF differs from --warn-nonroot-index=false (%d / %d bytes)", len(a), len(b))
	}
}

// TestCompileWarningsNoneToday は E013 の H3: 今の入力 (例・正の例・E010 の表) の build で SB021 は 0、compile_warnings.txt は空。
// 例の compile_warnings.txt は commit 済みの物と byte 同じ (空)。
// 例外 (P016 E068 — 意図して warning を出す正の例、文の要の句で固定): rec_array_idx_default は E274 (利用者の既定の定数と未知の添字 — E254 の形)、
// rec_array_var は E285 の M1 の範囲 (record の末尾の非 2 冪の配列)。他の入力は今も空。
var intendedWarnings = map[string]string{
	"rec_array_idx_default": "can be a constant on one path and a non-constant value on another",
	"early_return":          "can be a constant on one path and a non-constant value on another", // E073: program の直下の guard の添字は既定の 0 と lookup の値の合流 (E254 の形)
	"rec_array_var":         "the mask range of this ebpf.ref.index (\"v\", up to byte 36) reaches past the 24-byte record",
}

func TestCompileWarningsNoneToday(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	srcs, _ := filepath.Glob(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "*.rb"))
	tables, _ := filepath.Glob(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "table", "*.rb"))
	srcs = append(append(srcs, tables...), filepath.Join(repoRoot(), "examples", "xdpcount", "xdpcount.rb"))
	if len(srcs) < 14 { // E012 の 14 (E014 で packet の正の例が増えた)
		t.Fatalf("want at least the 14 inputs of E012, got %d", len(srcs))
	}
	for _, s := range srcs {
		d := t.TempDir()
		b, _ := os.ReadFile(s)
		p := filepath.Join(d, filepath.Base(s))
		os.WriteFile(p, b, 0o644)
		r, err := Build(cfg, p)
		if err != nil {
			t.Fatalf("%s: %v", s, err)
		}
		name := strings.TrimSuffix(filepath.Base(s), ".rb")
		cw, err := os.ReadFile(filepath.Join(d, name+".compile_warnings.txt"))
		if want, ok := intendedWarnings[name]; ok {
			if err != nil || strings.Count(string(cw), "warning:") != 1 || !strings.Contains(string(cw), want) || len(sb021(r.Output.Result.Diags)) != 1 {
				t.Errorf("%s: want exactly the intended warning %q (1 SB021), got %v %q", name, want, err, cw)
			}
			continue
		}
		if err != nil || len(cw) != 0 {
			t.Errorf("%s: want an empty compile_warnings.txt, got %v %q", name, err, cw)
		}
		if n := len(sb021(r.Output.Result.Diags)); n != 0 {
			t.Errorf("%s: %d SB021", name, n)
		}
		if name == "xdpcount" {
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "xdpcount", "xdpcount.compile_warnings.txt"))
			if err != nil || !bytes.Equal(cw, want) {
				t.Errorf("examples/xdpcount/xdpcount.compile_warnings.txt: %v (want the committed file, byte-equal)", err)
			}
		}
	}
}

// TestReuseCompileWarnings は E013 の H4: ebpf-compile の系が無い経路は commit 済みの compile_warnings.txt を同じ読み取りに通す —
// 空なら SB021 0、原文を置けば同じ SB021、無い・知らない形なら止める。
func TestReuseCompileWarnings(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	cfg.EbpfCompile = "/nonexistent/ebpf-compile"
	d := t.TempDir()
	src := copyExample(t, d)
	for _, f := range []string{"xdpcount.mlir", "xdpcount.schema.json", "xdpcount.maps.json", "xdpcount.bpf.o", "xdpcount_embed.o", "xdpcount.compile_warnings.txt"} {
		b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "xdpcount", f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, f), b, 0o644)
	}
	cwp := filepath.Join(d, "xdpcount.compile_warnings.txt")
	r, err := Build(cfg, src)
	if err != nil || !r.Reused || len(sb021(r.Output.Result.Diags)) != 0 {
		t.Fatalf("empty: want reuse without SB021, got %v (reused=%v)", err, r != nil && r.Reused)
	}
	orig := `loc("xdpcount.rb":19:11): warning: the index of ebpf.ref.index can be a constant on one path` + "\n" + `loc("xdpcount.rb":12:10): note: the constant index comes from here` + "\n"
	os.WriteFile(cwp, []byte(orig), 0o644)
	r, err = Build(cfg, src)
	if err != nil || !r.Reused {
		t.Fatalf("warning: want reuse, got %v", err)
	}
	ws := sb021(r.Output.Result.Diags)
	if len(ws) != 1 || ws[0].Pos.String() != "xdpcount.rb:19:11" || !strings.Contains(ws[0].Msg, "(note at xdpcount.rb:12:10: ") {
		t.Fatalf("want the same SB021 as a compile, got %v", ws)
	}
	os.WriteFile(cwp, []byte(`loc("xdpcount.rb":1:1): error: boom`+"\n"), 0o644)
	if _, err := Build(cfg, src); err == nil || !strings.Contains(err.Error(), "update spinelbpf's reader") {
		t.Fatalf("unknown shape: want a refusal, got %v", err)
	}
	os.Remove(cwp)
	if _, err := Build(cfg, src); err == nil || !strings.Contains(err.Error(), "compile_warnings.txt is missing") {
		t.Fatalf("missing: want a refusal, got %v", err)
	}
}

// TestCompileOutputShapes は E013 の H1 (build の側) と H5: fake の ebpf-compile で rc 0 の知らない行・stdout は止まり、
// rc ≠ 0 は warning があっても誤り (Ruby の位置に読み替え、warning: / error: の語が残る)。
func TestCompileOutputShapes(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	fake := func(body string) {
		p := filepath.Join(d, "fake-ebpf-compile")
		writeExec(t, p, []byte("#!/bin/sh\n"+body+"\n"))
		cfg.EbpfCompile = p
	}
	fake(`echo 'loc("p.rb":3:5): remark: new kind' >&2`)
	if _, err := compileELF(cfg, d, "p"); err != nil {
		t.Fatalf("compileELF reads stderr later, got %v", err)
	}
	stderr, _ := compileELF(cfg, d, "p")
	if err := addCompileWarnings(&frontend.Output{Result: &frontend.Result{}}, "", stderr); err == nil || !strings.Contains(err.Error(), "remark: new kind") {
		t.Fatalf("rc 0 unknown line: want a refusal with the line, got %v", err)
	}
	fake(`echo hello`)
	if _, err := compileELF(cfg, d, "p"); err == nil || !strings.Contains(err.Error(), "output on stdout") || !strings.Contains(err.Error(), "hello") {
		t.Fatalf("rc 0 stdout: want a refusal, got %v", err)
	}
	fake(`echo 'loc("p.rb":3:5): warning: w' >&2; echo 'loc("p.rb":4:6): error: e' >&2; exit 1`)
	_, err = compileELF(cfg, d, "p")
	if err == nil || !strings.Contains(err.Error(), "\np.rb:3:5: ebpf-compile: warning: w") || !strings.Contains(err.Error(), "\np.rb:4:6: ebpf-compile: error: e") || strings.Contains(err.Error(), d) {
		t.Fatalf("rc 1: want an error with the rewritten lines, got %v", err)
	}
	t.Logf("rc 1: %v", err)
}

// TestCompileWarningPosLikeFrontend は E013 のレビュー: SB021 の位置は frontend の診断 (SB013) と同じ形 — loc の file の名前 (絶対の path にしない)。
// unused_map (SB013 が 1 つ) を build し、生成した .mlir の op の loc を warning の行にして同じ build の結果に足す。
func TestCompileWarningPosLikeFrontend(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "unused_map.rb"))
	src := filepath.Join(d, "unused_map.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	m := regexp.MustCompile(`loc\("[^"]+":\d+:\d+\)`).FindString(r.Output.MLIR)
	if m == "" {
		t.Fatalf("no loc in the generated .mlir")
	}
	if err := addCompileWarnings(r.Output, "", m+": warning: w\n"+m+": note: n\n"); err != nil {
		t.Fatal(err)
	}
	var s13, s21 *frontend.Diag
	for i, x := range r.Output.Result.Diags {
		switch x.Code {
		case frontend.SB013MapDeclShape:
			s13 = &r.Output.Result.Diags[i]
		case frontend.SB021CompileWarning:
			s21 = &r.Output.Result.Diags[i]
		}
	}
	if s13 == nil || s21 == nil {
		t.Fatalf("want SB013 and SB021, got %v", r.Output.Result.Diags)
	}
	if s13.Pos.File != s21.Pos.File || filepath.IsAbs(s21.Pos.File) || strings.Contains(s21.Msg, d) {
		t.Fatalf("position forms differ: SB013 %q, SB021 %q (%s)", s13.Pos, s21.Pos, s21.Msg)
	}
	t.Logf("SB013 %s / SB021 %s", s13.Pos, s21)
}
