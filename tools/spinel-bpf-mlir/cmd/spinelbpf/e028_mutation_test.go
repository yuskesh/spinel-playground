//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestHookRingMutations は E028 の H4 (host、root): 変異の対照の検出器の列 — 各々で twin と kernel の出力が食い違い、最初の食い違いが意図した行と印の行。
// hook の 4 つ (frontend の lower・schema と maps.json・harness の双子の限度) は harness の生成の中で働き、discard は .mlir の text の変異 (submit → discard を ebpf-compile で直接)。
func TestHookRingMutations(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	script := tRingScript()
	for _, m := range []struct {
		name, hook string
		row, line  string // 最初の食い違いの行の印と、その行の出力の接頭辞
	}{
		{"invert (if_reserved の yield の true / false)", "ring-invert", "bounds_x=0_y=0", "Cnt[0]="},
		{"swap (record.make の a / b)", "ring-swap", "bounds_x=4294967296_y=0", "Events#0.a="},
		{"size (schema と maps.json の大きさを 2 倍)", "ring-size", "fill_if_128", "Cnt[0]="},
		{"model (双子の限度を size に)", "ring-model", "fill_if_128", "Cnt[0]="},
		{"discard (submit → discard の text の変異)", "", "bounds_x=0_y=0", "Events"},
	} {
		var h harnessSet
		if m.hook != "" {
			t.Setenv("SPINELBPF_MUTATION", m.hook)
			h = buildHarnesses(t, tRingSrc())
			os.Unsetenv("SPINELBPF_MUTATION")
		} else {
			h = discardRing(t)
		}
		tw := feed(t, false, script, h.twinBin)
		kn := feed(t, true, script, h.kernelBin)
		d := ringDiff(tw, kn)
		t.Logf("%s: %s", m.name, d)
		want := "row " + m.row + " "
		if d == "" || !strings.HasPrefix(d, want) || !strings.Contains(d, ": \""+m.line) {
			t.Errorf("%s: want the first difference at row %s on %q, got %q", m.name, m.row, m.line, d)
		}
	}
}

// discardRing は t_ring の kernel の harness を .mlir の submit を discard に書き換えて作り直す (schema は同じ — 埋め込みの ELF だけ差し替え)。
func discardRing(t *testing.T) harnessSet {
	t.Helper()
	h := buildHarnesses(t, tRingSrc())
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	b, _ := os.ReadFile(filepath.Join(d, "t_ring.mlir"))
	m := strings.ReplaceAll(string(b), "ebpf.ringbuf.submit", "ebpf.ringbuf.discard")
	if m == string(b) {
		t.Fatal("the rewrite did not apply")
	}
	os.WriteFile(filepath.Join(d, "t_ring.mlir"), []byte(m), 0o644)
	if err := runIn(d, cfg.EbpfCompile, "t_ring.mlir", "--schema", "t_ring.schema.json", "-o", "t_ring.bpf.o"); err != nil {
		t.Fatal(err)
	}
	if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "t_ring_embed.S", "-o", "t_ring_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(d, "kernel_mut")
	if err := Link(cfg, filepath.Join(d, "t_ring.rb"), mut); err != nil {
		t.Fatal(err)
	}
	h.kernelBin = mut
	return h
}

// TestHookRingMultiCPU は E028 の H5 の変異の対照 (root): hook ring-invert の ELF では受け取った数 + 落ちた数 = 送った数が崩れる (等式が検出器として効く)。
func TestHookRingMultiCPU(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cpus, sent, received, dropped := ringMC(t, "ring-invert", 20000)
	if received+dropped == sent {
		t.Errorf("the equation still holds under ring-invert (received %d + dropped %d = sent %d on %d CPUs)", received, dropped, sent, cpus)
	}
}
