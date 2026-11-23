package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// TestGlobalsCompile は E057 の H1 (P014): glob_basic の build — .mlir の global の op (i32 の add の前の trunci)、maps.json の globals、埋め込みの表の G の行、
// ELF の .rodata と .bss。load はしない (E058)。
func TestGlobalsCompile(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "glob_basic.rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, "glob_basic.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	read := func(f string) string { x, _ := os.ReadFile(filepath.Join(d, f)); return string(x) }
	m := read("glob_basic.mlir")
	for _, w := range []string{"ebpf.global.load @Port : i16", "ebpf.global.load @Verbose : i8", "ebpf.global.atomic_add @Hits, ", " : i64", "arith.trunci", "ebpf.global.atomic_add @Neg, "} {
		if !strings.Contains(m, w) {
			t.Errorf(".mlir lacks %q", w)
		}
	}
	mj := read("glob_basic.maps.json")
	for _, w := range []string{`"name": "Port"`, `"section": "rodata"`, `"type": "u16"`, `"name": "Hits"`, `"section": "bss"`, `"type": "i32"`} {
		if !strings.Contains(mj, w) {
			t.Errorf("maps.json lacks %q", w)
		}
	}
	if !strings.Contains(read("glob_basic_embed.S"), `G|Port|rodata|u16|0\nG|Verbose|rodata|u8|1\nG|Hits|bss|u64|0\nG|Neg|bss|i32|0\n`) {
		t.Errorf("the embedded table lacks the G rows")
	}
	h, _ := exec.Command(filepath.Join(filepath.Dir(cfg.Clang), "llvm-objdump"), "-h", filepath.Join(d, "glob_basic.bpf.o")).Output()
	if !strings.Contains(string(h), ".rodata") || !strings.Contains(string(h), ".bss") {
		t.Errorf("the ELF lacks .rodata / .bss:\n%s", h)
	}
}
