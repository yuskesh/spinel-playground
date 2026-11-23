package main

import (
	"fmt"
	"strings"
	"testing"
)

// E071 の試験: 条件の区間の狭め (P017) の kernel の差動・変異 (実行の時の検査が ELF に残る)・E294 の形の load。

var narrowKs = []string{"-1000", "-1", "0", "1", "7", "8", "15", "16", "17", "999", "1000"}

// narrowScript は行ごとに reset → Hs[0].hist[m] = 100 + m・Hs[0].n = 777・Out[0..4] = 999 → In → run → dump。
func narrowScript() string {
	var b strings.Builder
	for r, k := range narrowKs {
		fmt.Fprintf(&b, "echo r%d\nreset\n", r)
		for m := 0; m < 8; m++ {
			fmt.Fprintf(&b, "poke Hs 0 hist[%d] %d\n", m, 100+m)
		}
		b.WriteString("poke Hs 0 n 777\n")
		for m := 0; m < 5; m++ {
			fmt.Fprintf(&b, "poke Out %d 999\n", m)
		}
		fmt.Fprintf(&b, "poke In 0 %s\nrun prog\ndump\n", k)
	}
	return b.String()
}

// TestNarrowTable は E071 の H1〜H4 (root): 11 行の一致と、変異 3 つの食い違う行と slot (と kernel の値)。
func TestNarrowTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, posSrc("narrow_basic"))
	s := narrowScript()
	tw := feed(t, false, s, h.twinBin)
	kn := feed(t, true, s, h.kernelBin)
	if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
		t.Fatalf("an error line — twin:\n%s\nkernel:\n%s", tw, kn)
	}
	for i, x := range loopDiff(t, tw, kn, len(narrowKs)) {
		t.Errorf("row %d (k %s): twin and kernel differ in %v", i, narrowKs[i], keysOf(x))
	}
	in := func(ks ...string) func(string) bool {
		return func(k string) bool {
			for _, x := range ks {
				if x == k {
					return true
				}
			}
			return false
		}
	}
	for _, c := range []struct {
		name    string
		rewrite func(string) (string, bool)
		slot    string
		want    func(string) bool
		kval    string // 食い違う行の kernel の値 ("" は問わない)
	}{
		{"M1 k<8 -> k<=8", replaceFirst("arith.cmpi slt,", "arith.cmpi sle,"), "Out[0]", in("8"), "0"},
		{"M2 no bound", func(m string) (string, bool) {
			b := boundOf(m, 16)
			if b == "" {
				return m, false
			}
			return strings.Replace(m, "ebpf.loop 16 unroll bound("+b+")", "ebpf.loop 16 unroll", 1), true
		}, "Out[1]", in("1", "7", "8", "15"), "120"},
		{"M3 loop 16 -> 15", replaceFirst("ebpf.loop 16 unroll", "ebpf.loop 15 unroll"), "Out[1]", in("16"), "105"},
	} {
		t.Run(c.name, func(t *testing.T) {
			mut, _, _ := mutatedKernelNamed(t, h, "narrow_basic", c.rewrite)
			km := feed(t, true, s, mut)
			d := loopDiff(t, tw, km, len(narrowKs))
			blocks := loopBlocks(t, km, len(narrowKs))
			for i, k := range narrowKs {
				x, differs := d[i]
				if differs != c.want(k) {
					t.Errorf("row %d (k %s): differs=%v, want %v (%v)", i, k, differs, c.want(k), keysOf(x))
				}
				for sl := range x {
					if sl != c.slot {
						t.Errorf("row %d (k %s): unexpected slot %s differs", i, k, sl)
					}
				}
				if differs && c.kval != "" && blocks[i][c.slot] != c.kval {
					t.Errorf("row %d (k %s): kernel %s=%s, want %s", i, k, c.slot, blocks[i][c.slot], c.kval)
				}
			}
			t.Logf("%s: %d rows differ", c.name, len(d))
		})
	}
}

// TestNarrowE294Load は E071 の H5 (root): E294 の形 (閾値 < 要素の数・腕の helper) は警告無しで build でき、root の host で load できる。
func TestNarrowE294Load(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := buildPos(t, "narrow_e294", "\nrequire \"spinelbpf\"\nobj = SpinelBPF.load_embedded\nputs \"loaded unmet=#{obj.unmet.length}\"\nobj.close\n")
	if w := readIn(t, d, "narrow_e294.compile_warnings.txt"); w != "" {
		t.Errorf("compile warnings (E294 is a shape bpf-mlir does not warn about):\n%s", w)
	}
	exe := d + "/narrow_e294"
	if err := Link(cfg, d+"/narrow_e294.rb", exe); err != nil {
		t.Fatal(err)
	}
	if out := feed(t, true, "", exe); !strings.Contains(out, "loaded unmet=0") {
		t.Errorf("%s", out)
	}
}
