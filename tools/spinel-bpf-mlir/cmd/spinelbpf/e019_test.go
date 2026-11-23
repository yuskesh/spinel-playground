package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E019 の試験: v0.11.0 の新しい warning (mask の範囲 — bpf-mlir E285) と知らない warning の文の SB021 (P005 §2)。

// m1fitInput は bpf-mlir の test/Target/EBPF/Inputs/m1fit/c5_end/a_two_c5_end.mlir (loc の無い入力) の 2 つの ref.index (28:7 — region を閉じる 34 行の後、
// 42:7 — 51 行の後。lit の FileCheck は 1 つ目だけを見る — E019 の 1 回目に 1 つと読み違えた) に
// Ruby の名前の loc を明示して dir に m1.mlir と m1.schema.json を置く (E013 の idxInput の形)。
func m1fitInput(t *testing.T, dir string) {
	t.Helper()
	src := filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "bpfmlir", "m1fit_c5_end") // E161 追補 2: bpf-mlir の写し (PROVENANCE)
	b, err := os.ReadFile(filepath.Join(src, "a_two_c5_end.mlir"))
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(string(b), "\n")
	if !strings.Contains(lines[27], `ebpf.ref.index %b "hist" [%i]`) || strings.TrimSpace(lines[33]) != "}" ||
		!strings.Contains(lines[41], `ebpf.ref.index %b2 "hist" [%i]`) || strings.TrimSpace(lines[50]) != "}" {
		t.Fatalf("a_two_c5_end.mlir changed shape:\n%s", b)
	}
	lines[33] += ` loc("m1.rb":28:7)`
	lines[50] += ` loc("m1.rb":42:7)`
	os.WriteFile(filepath.Join(dir, "m1.mlir"), []byte(strings.Join(lines, "\n")), 0o644)
	s, err := os.ReadFile(filepath.Join(src, "schema.json"))
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "m1.schema.json"), s, 0o644)
}

// TestMaskRangeWarning は E019 の H1・H2: rc 0・SB021 が 2 つ (m1.rb:28:7 と 42:7 — 仮説の「1 つ」は入力の読み違い)・原文と既知の直し方 2 つ・止まらない・ELF は --tune-mask-checked-index を明示した build と同じ。
func TestMaskRangeWarning(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	m1fitInput(t, d)
	stderr, err := compileELF(cfg, d, "m1")
	if err != nil {
		t.Fatalf("want rc 0, got %v", err)
	}
	out := &frontend.Output{Result: &frontend.Result{}}
	if err := addCompileWarnings(out, "", stderr); err != nil {
		t.Fatal(err)
	}
	ws := sb021(out.Result.Diags)
	if len(ws) != 2 || out.Result.Diags.Blocking() || ws[1].Pos.String() != "m1.rb:42:7" {
		t.Fatalf("want two non-blocking SB021 (28:7 and 42:7), got %v\nstderr:\n%s", out.Result.Diags, stderr)
	}
	s := ws[0].String()
	t.Log(s)
	for _, want := range []string{"m1.rb:28:7: conditional SB021 (CompileWarning): ebpf-compile: the mask range of this ebpf.ref.index (\"hist\", up to byte 36) reaches past the 24-byte record",
		"keep a constant default out of the index", "inside the present region;", "up to the next power of two"} {
		if !strings.Contains(s, want) {
			t.Errorf("SB021 lacks %q", want)
		}
	}
	c := exec.Command(cfg.EbpfCompile, "m1.mlir", "--schema", "m1.schema.json", "--line-info="+cfg.LineInfo, "--tune-mask-checked-index", "-o", "m1x.bpf.o")
	c.Dir = d
	o, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("explicit: %v %s", err, o)
	}
	a, _ := os.ReadFile(filepath.Join(d, "m1.bpf.o"))
	b, _ := os.ReadFile(filepath.Join(d, "m1x.bpf.o"))
	if len(a) == 0 || !bytes.Equal(a, b) {
		t.Fatal("the ELF differs from the explicit --tune-mask-checked-index build")
	}
}

// TestIdxConstWarningFixes は E019 の H2: E013 の idx_const の SB021 にも同じ直し方の案内が付く (種類で分けない)。
func TestIdxConstWarningFixes(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	idxInput(t, d)
	stderr, err := compileELF(cfg, d, "idx")
	if err != nil {
		t.Fatal(err)
	}
	out := &frontend.Output{Result: &frontend.Result{}}
	if err := addCompileWarnings(out, "", stderr); err != nil {
		t.Fatal(err)
	}
	ws := sb021(out.Result.Diags)
	if len(ws) != 1 || !strings.Contains(ws[0].Msg, "put the ref.index inside the present region") || !strings.Contains(ws[0].Msg, "up to the next power of two") {
		t.Fatalf("want one SB021 with both known fixes, got %v", ws)
	}
}

// TestUnknownWarningText は E019 の H3: 知らない warning の文も原文のまま SB021 (build は止まらない)、remark は止まる。
func TestUnknownWarningText(t *testing.T) {
	parallel(t) // P018 E075
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d := t.TempDir()
	p := filepath.Join(d, "fake-ebpf-compile")
	writeExec(t, p, []byte("#!/bin/sh\necho 'loc(\"p.rb\":3:5): warning: a new kind of warning nobody knows' >&2\n"))
	cfg.EbpfCompile = p
	stderr, err := compileELF(cfg, d, "p")
	if err != nil {
		t.Fatal(err)
	}
	out := &frontend.Output{Result: &frontend.Result{}}
	if err := addCompileWarnings(out, "", stderr); err != nil {
		t.Fatalf("an unknown warning text must not stop the build: %v", err)
	}
	ws := sb021(out.Result.Diags)
	if len(ws) != 1 || ws[0].Pos.String() != "p.rb:3:5" || !strings.HasPrefix(ws[0].Msg, "ebpf-compile: a new kind of warning nobody knows — known fixes") {
		t.Fatalf("want the unknown warning verbatim as SB021, got %v", ws)
	}
	if err := addCompileWarnings(&frontend.Output{Result: &frontend.Result{}}, "", "loc(\"p.rb\":3:5): remark: r\n"); err == nil {
		t.Fatal("a remark must still stop the build (E013)")
	}
}
