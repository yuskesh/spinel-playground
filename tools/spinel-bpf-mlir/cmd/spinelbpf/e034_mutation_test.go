//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestHookHashMutations は E034 の H2 (host、root): 変異の対照の検出器の列 — 各々で twin と kernel の出力が食い違い、最初の食い違いが意図した行に在り、その行の中身に印の文字列がある。
// hook の 4 つ (frontend の flags・key の並び・errno、harness の双子の容量) は harness の生成の中で働き、delete-drop は .mlir の text の変異 (try_delete を status 0 の定数に)。
func TestHookHashMutations(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	script := tHashScript()
	for _, m := range []struct {
		name, hook string
		row, line  string
	}{
		{"flags (noexist ↔ exist)", "hash-flags", "h_ops", "H{7}="},
		{"key-swap (record の key の a / b)", "hash-key-swap", "r_ops", "R{"},
		{"errno (BPF::ENOENT を +2 に)", "hash-errno", "h_ops", "Out[1]="},
		{"cap (双子の容量を max_entries + 1 に)", "hash-cap", "h_full", "H{5}="},
		{"delete-drop (try_delete を status 0 に)", "", "h_ops", "H{7}="},
	} {
		var h harnessSet
		if m.hook != "" {
			t.Setenv("SPINELBPF_MUTATION", m.hook)
			h = buildHarnesses(t, tHashSrc())
			os.Unsetenv("SPINELBPF_MUTATION")
		} else {
			h = deleteDropHash(t)
		}
		tw := feed(t, false, script, h.twinBin)
		kn := feed(t, true, script, h.kernelBin)
		d := ringDiff(tw, kn)
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row "+m.row+" ") || !strings.Contains(d, "\""+m.line) { // 印の文字列は食い違いの両側のどちらか (dump は map の宣言の順 — hash の中身が Out より先)
			t.Errorf("%s: want the first difference at row %s on %q, got %q", m.name, m.row, m.line, d)
		}
	}
}

// deleteDropHash は t_hash の kernel の harness を .mlir の `%v = ebpf.map.try_delete …` を `%v = arith.constant 0 : i64` に書き換えて作り直す (delete を捨てる形)。
func deleteDropHash(t *testing.T) harnessSet {
	t.Helper()
	h := buildHarnesses(t, tHashSrc())
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	b, _ := os.ReadFile(filepath.Join(d, "t_hash.mlir"))
	re := regexp.MustCompile(`(%v\d+) = ebpf\.map\.try_delete [^\n]*? (loc\([^\n]*\))\n`)
	m := re.ReplaceAllString(string(b), "$1 = arith.constant 0 : i64 $2\n")
	if m == string(b) {
		t.Fatal("the rewrite did not apply")
	}
	os.WriteFile(filepath.Join(d, "t_hash.mlir"), []byte(m), 0o644)
	if err := runIn(d, cfg.EbpfCompile, "t_hash.mlir", "--schema", "t_hash.schema.json", "-o", "t_hash.bpf.o"); err != nil {
		t.Fatal(err)
	}
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "t_hash_embed.S", "-o", "t_hash_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(d, "kernel_mut")
	if err := Link(cfg, filepath.Join(d, "t_hash.rb"), mut); err != nil {
		t.Fatal(err)
	}
	h.kernelBin = mut
	return h
}
