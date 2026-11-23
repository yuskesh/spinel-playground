package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E068 の試験: record の配列の member の可変の添字 (P016) — ref.index の形・M1 の ELF の確かめ・E254 の形の warning・host の load・双子の smoke。

func posSrc(name string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb")
}

// buildPos は正の例を一時の directory に build して、その directory を返す。
func buildPos(t *testing.T, name, extra string) string {
	t.Helper()
	cfg, _ := defaultConfig()
	b, err := os.ReadFile(posSrc(name))
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e068-")
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(d, name+".rb"), append(b, []byte(extra)...), 0o644)
	if _, err := Build(cfg, filepath.Join(d, name+".rb")); err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return d
}

func readIn(t *testing.T, d, f string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(d, f))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// TestRecordArrayVarIndex は E068 の H1〜H3: ref.index の数、compile の warning (E274 の有無)、loop の IV の ELF は M1 無し (E301) と可変の添字は M1 在り。
func TestRecordArrayVarIndex(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	const e274 = "can be a constant on one path and a non-constant value on another"
	m1 := func(d, name string) bool { // M1 が出ているか (--tune-mask-checked-index=false の ELF と違う)
		if err := runIn(d, cfg.EbpfCompile, name+".mlir", "--schema", name+".schema.json", "--tune-mask-checked-index=false", "-o", "m1off.o"); err != nil {
			t.Fatal(err)
		}
		a, b := readIn(t, d, name+".bpf.o"), readIn(t, d, "m1off.o")
		return !bytes.Equal([]byte(a), []byte(b))
	}
	v := buildPos(t, "rec_array_var", "")
	if n := strings.Count(readIn(t, v, "rec_array_var.mlir"), "ebpf.ref.index"); n != 3 {
		t.Errorf("rec_array_var: %d ebpf.ref.index, want 3", n)
	}
	if w := readIn(t, v, "rec_array_var.compile_warnings.txt"); strings.Contains(w, e274) {
		t.Errorf("rec_array_var: an E274 warning (E254 shape) — the frontend's lowering must not create it:\n%s", w)
	}
	if !m1(v, "rec_array_var") {
		t.Errorf("rec_array_var: the variable index has no M1 mask (the ELF is the same with --tune-mask-checked-index=false)")
	}
	l := buildPos(t, "rec_array_loop_iv", "")
	if w := readIn(t, l, "rec_array_loop_iv.compile_warnings.txt"); w != "" {
		t.Errorf("rec_array_loop_iv: compile warnings:\n%s", w)
	}
	if m1(l, "rec_array_loop_iv") {
		t.Errorf("rec_array_loop_iv: M1 masks the loop IV index (E301 — the unrolled index should be a direct constant)")
	}
	dd := buildPos(t, "rec_array_idx_default", "")
	if w := readIn(t, dd, "rec_array_idx_default.compile_warnings.txt"); !strings.Contains(w, e274) {
		t.Errorf("rec_array_idx_default: want the E274 warning (the user's constant default and the lookup value reach the same index), got:\n%s", w)
	}
}

// TestRecordArrayVarHost は E068 の H1・H2 の load と H6 (root): 正の例の host の load と、rec_array_var の双子と kernel の smoke。
func TestRecordArrayVarHost(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	for _, name := range []string{"rec_array_var", "rec_array_loop_iv", "rec_array_idx_default"} {
		d := buildPos(t, name, "\nrequire \"spinelbpf\"\nobj = SpinelBPF.load_embedded\nputs \"loaded unmet=#{obj.unmet.length}\"\nobj.close\n")
		exe := filepath.Join(d, name)
		if err := Link(cfg, filepath.Join(d, name+".rb"), exe); err != nil {
			t.Fatal(err)
		}
		if out := feed(t, true, "", exe); !strings.Contains(out, "loaded unmet=0") {
			t.Errorf("%s: %s", name, out)
		}
	}
	h := buildHarnesses(t, posSrc("rec_array_var"))
	var b strings.Builder
	rows := 0
	for _, in := range []string{"0", "7", "63", "200"} { // i = in & 7・j = (in >> 3) & 7・u = (in & 0xFF) % 5
		fmt.Fprintf(&b, "echo r%d\nreset\npoke In 0 %s\npoke Hs 0 hist[0] 100\npoke Hs 0 hist[7] 107\npoke Ps 0 v[0] 50\npoke Ps 0 v[4] 54\nrun prog\ndump\n", rows, in)
		rows++
	}
	tw := feed(t, false, b.String(), h.twinBin)
	kn := feed(t, true, b.String(), h.kernelBin)
	if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
		t.Fatalf("an error line — twin:\n%s\nkernel:\n%s", tw, kn)
	}
	for i, s := range loopDiff(t, tw, kn, rows) {
		t.Errorf("row %d: twin and kernel differ in %v", i, keysOf(s))
	}
	if !strings.Contains(tw, "Out[0]=107") { // in 7 の行: i = 7 → hist[7]
		t.Errorf("the twin never read hist[7]:\n%s", tw)
	}
}
