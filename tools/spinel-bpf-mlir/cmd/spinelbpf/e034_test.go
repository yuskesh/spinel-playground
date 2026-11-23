package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E034 の試験: hash の差動 (双子の status と容量の model — P008 §4)。

func tHashSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "hash", "t_hash.rb")
}

// tHashScript は t_hash の表 (期待の値を持たない)。行は `echo <label>` で始まり、reset の後に (op, k1, k2, v) の操作を 1 つずつ run して dump する。
func tHashScript() string {
	var b strings.Builder
	step := func(prog string, op, k1, k2, v int64) {
		fmt.Fprintf(&b, "poke In 0 %d\npoke In 1 %d\npoke In 2 %d\npoke In 3 %d\nrun %s\ndump\n", op, k1, k2, v, prog)
	}
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	// v は (In[3] & 0xFFFF) − 32768 — 32868 は 100、32768 は 0、0 は −32768、65535 は 32767
	row("h_ops") // 空の表の 1 つの key に全ての op
	for _, op := range []int64{1, 1, 2, 0, 4, 4, 3, 3, 5, 2} {
		step("t_h", op, 7, 0, 32868)
	}
	row("h_missing")
	for _, op := range []int64{2, 3, 5, 4, 4} {
		step("t_h", op, 9, 0, 32770)
	}
	row("h_full") // max_entries 4: 5 つ目の新しい key・満杯での置き換え・消した後の insert
	for _, k := range []int64{1, 2, 3, 4} {
		step("t_h", 1, k, 0, 32769)
	}
	step("t_h", 1, 5, 0, 32769)
	step("t_h", 0, 5, 0, 32769)
	step("t_h", 0, 3, 0, 65535)
	step("t_h", 4, 6, 0, 32769)
	step("t_h", 4, 3, 0, 32769)
	step("t_h", 3, 2, 0, 0)
	step("t_h", 1, 5, 0, 0)
	row("h_bounds")
	step("t_h", 0, 4294967295, 0, 0)
	step("t_h", 0, 0, 0, 65535)
	step("t_h", 0, 2147483648, 0, 32768)
	row("r_ops") // record の key: a = k1 & 0xFFFF、b = k1 >> 16、c = k2
	for _, k := range [][2]int64{{0, 0}, {65535 + 1<<16, 4294967295}, {1 + 65535<<16, 7}} {
		for _, op := range []int64{1, 1, 2, 4, 3, 3} {
			step("t_r", op, k[0], k[1], 32800)
		}
		step("t_r", 1, k[0], k[1], 32800)
	}
	row("r_full")
	for i := int64(0); i < 5; i++ {
		step("t_r", 0, i, i, 32768+i)
	}
	row("l_evict") // lru_hash (4): 6 つの key — status は全て 0、数は 4 (どの key が残るかは比べない)
	for k := int64(1); k <= 6; k++ {
		step("t_l", 0, k, 0, k)
	}
	return b.String()
}

// TestHashTable は E034 の H1・H3 (host、root): t_hash の表で twin (Spinel)・kernel・CRuby が byte 一致、満杯の行は −7・満杯での置き換えは 0・LRU は count 4。
func TestHashTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, tHashSrc())
	script := tHashScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	rb := crubyFeed(t, script, h)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	if d := ringDiff(tw, rb); d != "" {
		t.Errorf("twin / CRuby: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## h_full\n", "Out[0]=-7\n", "## l_evict\n", "L count=4\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestHashTableOut は E034 の成果物: 表の手順と kernel の出力を E034_OUT に残す。
func TestHashTableOut(t *testing.T) {
	parallel(t) // P018 E075
	o := os.Getenv("E034_OUT")
	if o == "" {
		t.Skip("E034_OUT")
	}
	h := buildHarnesses(t, tHashSrc())
	script := tHashScript()
	os.WriteFile(filepath.Join(o, "t_hash.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_hash.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
}
