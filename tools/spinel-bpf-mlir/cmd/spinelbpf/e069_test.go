package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E069 の試験: record の配列の member の表 (t_arr.rb — 8 行) の双子と kernel の差動と、kernel の .mlir の書き換えの変異 5 つ (P016 §3)。

var arrKs = []string{"0", "1", "7", "8", "63", "69", "12345", "4294967295"}

// arrScript は行ごとに reset → Hs[0].hist[m] = 100 + m・Hs[1].hist[m] = m × m・Ps[0].v[m] = 50 + m → In → run → dump。
func arrScript() string {
	var b strings.Builder
	for r, k := range arrKs {
		fmt.Fprintf(&b, "echo r%d\nreset\n", r)
		for m := 0; m < 8; m++ {
			fmt.Fprintf(&b, "poke Hs 0 hist[%d] %d\npoke Hs 1 hist[%d] %d\n", m, 100+m, m, m*m)
		}
		for m := 0; m < 5; m++ {
			fmt.Fprintf(&b, "poke Ps 0 v[%d] %d\n", m, 50+m)
		}
		fmt.Fprintf(&b, "poke In 0 %s\nrun prog\ndump\n", k)
	}
	return b.String()
}

func arrSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "arr", "t_arr.rb")
}

// TestRecordArrayTable は E069 の H1 (root): 8 行で双子と kernel の dump が一致。
func TestRecordArrayTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, arrSrc())
	s := arrScript()
	tw := feed(t, false, s, h.twinBin)
	kn := feed(t, true, s, h.kernelBin)
	if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
		t.Fatalf("an error line — twin:\n%s\nkernel:\n%s", tw, kn)
	}
	d := loopDiff(t, tw, kn, len(arrKs))
	for i, x := range d {
		t.Errorf("row %d (k %s): twin and kernel differ in %v", i, arrKs[i], keysOf(x))
	}
	t.Logf("%d rows, %d differing", len(arrKs), len(d))
}

// mutatedArrKernel は t_arr の kernel の harness を .mlir の書き換え (と ebpf-compile の追加の flag) で build し直す (今の embed.S を組み立て直す — E059)。
func mutatedArrKernel(t *testing.T, h harnessSet, rewrite func(string) (string, bool), flags ...string) (string, []byte, []byte) {
	t.Helper()
	return mutatedKernelNamed(t, h, "t_arr", rewrite, flags...)
}

// mutatedKernelNamed は program の名前の kernel の harness を .mlir の書き換え (と ebpf-compile の追加の flag) で build し直す (E071 で一般に)。
func mutatedKernelNamed(t *testing.T, h harnessSet, name string, rewrite func(string) (string, bool), flags ...string) (string, []byte, []byte) {
	t.Helper()
	cfg, _ := defaultConfig()
	d := filepath.Dir(h.kernelBin)
	m, err := os.ReadFile(filepath.Join(d, name+".mlir"))
	if err != nil {
		t.Fatal(err)
	}
	mm := string(m)
	if rewrite != nil {
		var ok bool
		if mm, ok = rewrite(mm); !ok || mm == string(m) {
			t.Fatalf("the rewrite did not apply to %s.mlir", name)
		}
	}
	md := t.TempDir()
	for _, f := range []string{name + ".rb", name + ".schema.json", name + ".maps.json", name + "_embed.S"} {
		b, err := os.ReadFile(filepath.Join(d, f))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(md, f), b, 0o644)
	}
	os.WriteFile(filepath.Join(md, name+".mlir"), []byte(mm), 0o644)
	if err := runIn(md, cfg.EbpfCompile, append([]string{name + ".mlir", "--schema", name + ".schema.json", "-o", name + ".bpf.o"}, flags...)...); err != nil {
		t.Fatal(err)
	}
	if err := runIn(md, cfg.Clang, "-c", "-x", "assembler", name+"_embed.S", "-o", name+"_embed.o"); err != nil {
		t.Fatal(err)
	}
	mut := filepath.Join(md, "kernel_mut")
	if err := Link(cfg, filepath.Join(md, name+".rb"), mut); err != nil {
		t.Fatal(err)
	}
	orig, _ := os.ReadFile(filepath.Join(d, name+".bpf.o"))
	now, _ := os.ReadFile(filepath.Join(md, name+".bpf.o"))
	return mut, orig, now
}

// TestRecordArrayMutations は E069 の H2〜H6 (root): 変異ごとに食い違う行と slot が予測どおり。
func TestRecordArrayMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, arrSrc())
	s := arrScript()
	tw := feed(t, false, s, h.twinBin)
	firstLoad := regexp.MustCompile(`(%v\d+) = ebpf\.elem\.load %v\d+ : !ebpf\.elem<i32> -> i32`)
	firstIndex := regexp.MustCompile(`ebpf\.ref\.index (%v\d+) "hist" \[(%v\d+)\] : (!ebpf\.borrowed<[^>]*>>), i32 -> i32 in_range \{`)
	storeRe := regexp.MustCompile(`ebpf\.elem\.store (%v\d+), (%v\d+) : !ebpf\.elem<i32>, i32`)
	for _, c := range []struct {
		name    string
		rewrite func(string) (string, bool)
		flags   []string
		slots   []string
		want    func(k string) bool
	}{
		{"M1 in_range value 0", func(m string) (string, bool) {
			x := firstLoad.FindStringSubmatchIndex(m)
			if x == nil {
				return m, false
			}
			return m[:x[0]] + m[x[2]:x[3]] + " = arith.constant 0 : i32" + m[x[1]:], true
		}, nil, []string{"Out[0]"}, func(string) bool { return true }},
		{"M2 index +1", func(m string) (string, bool) {
			x := firstIndex.FindStringSubmatchIndex(m)
			if x == nil {
				return m, false
			}
			line := strings.LastIndex(m[:x[0]], "\n") + 1 // 行の頭 (`%vN = ebpf.ref.index` の結果の名前の前) に挿す
			ind := m[line : line+len(m[line:])-len(strings.TrimLeft(m[line:], " "))]
			idx := m[x[4]:x[5]]
			pre := fmt.Sprintf("%s%%m2c = arith.constant 1 : i32\n%s%%m2i = arith.addi %s, %%m2c : i32\n", ind, ind, idx)
			return m[:line] + pre + m[line:x[0]] + strings.Replace(m[x[0]:x[1]], "["+idx+"]", "[%m2i]", 1) + m[x[1]:], true
		}, nil, []string{"Out[0]"}, func(string) bool { return true }},
		{"M3 no mask", nil, []string{"--tune-mask-checked-index=false"}, nil, func(string) bool { return false }},
		{"M4 loop 8 -> 7", replaceFirst("ebpf.loop 8 unroll", "ebpf.loop 7 unroll"), nil, []string{"Out[3]"}, func(string) bool { return true }},
		{"M5 store 0", func(m string) (string, bool) {
			x := storeRe.FindStringSubmatchIndex(m)
			if x == nil {
				return m, false
			}
			line := strings.LastIndex(m[:x[0]], "\n") + 1
			ind := m[line:x[0]]
			return m[:x[0]] + "%m5z = arith.constant 0 : i32\n" + ind + "ebpf.elem.store " + m[x[2]:x[3]] + ", %m5z : !ebpf.elem<i32>, i32" + m[x[1]:], true
		}, nil, []string{"Hs"}, func(k string) bool { return k != "0" }},
	} {
		t.Run(c.name, func(t *testing.T) {
			mut, orig, now := mutatedArrKernel(t, h, c.rewrite, c.flags...)
			if c.rewrite == nil && string(orig) == string(now) {
				t.Errorf("the ELF with %v is the same as the plain one — no mask was there to remove", c.flags)
			}
			kn := feed(t, true, s, mut)
			d := loopDiff(t, tw, kn, len(arrKs))
			allowed := map[string]bool{}
			for _, x := range c.slots {
				allowed[x] = true
			}
			got := 0
			for i, k := range arrKs {
				x, differs := d[i]
				if differs {
					got++
				}
				if differs != c.want(k) {
					t.Errorf("row %d (k %s): differs=%v, want %v (%v)", i, k, differs, c.want(k), keysOf(x))
				}
				for sl := range x {
					if !allowed[sl] {
						t.Errorf("row %d (k %s): unexpected slot %s differs", i, k, sl)
					}
				}
			}
			t.Logf("%s: %d rows differ", c.name, got)
		})
	}
}

var bytehistArtefacts = []string{"bytehist.mlir", "bytehist.schema.json", "bytehist.maps.json", "bytehist.domain.json", "bytehist.bpf.o",
	"bytehist.compile_warnings.txt", "bytehist_embed.S", "bytehist_embed.o"}

// TestBytehistArtefacts は E069 の H7: 2 回の build の生成物が commit 済みの物と byte 同じ (compile_warnings は空)。
func TestBytehistArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "bytehist", "bytehist.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "bytehist.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range bytehistArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "bytehist", f))
			if err != nil || string(got) != string(want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
			if f == "bytehist.compile_warnings.txt" && len(got) != 0 {
				t.Errorf("compile warnings: %q", got)
			}
		}
	}
}

// TestBytehistSelftestHost は E069 の H7 (root): 7 つの packet で CPU ごとの和が bucket 4 に 3・6 に 2・15 に 1。
func TestBytehistSelftestHost(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "bytehist", "bytehist.rb"))
	src := filepath.Join(d, "bytehist.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "bytehist")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "counts=0,0,0,0,3,0,2,0,0,0,0,0,0,0,0,1\nselftest ok") {
		t.Errorf("selftest failed")
	}
}
