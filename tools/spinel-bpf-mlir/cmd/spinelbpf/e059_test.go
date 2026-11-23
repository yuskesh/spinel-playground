package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// E059 の試験 (P014 — host、root): global の counter の並行の保存則 (Thread の harness — kernel は 8 Thread の並行、双子は直列)。

func countScript() string {
	var hs []string
	for i := 0; i < 8; i++ {
		hs = append(hs, pkt(i, i+1)) // byte 1 は Thread ごとに 1..8
	}
	return "load\nprun prog 200 " + strings.Join(hs, " ") + "\ndump\n"
}

func globalLines(out string) (string, string) {
	var hits, bytes string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "Hits=") {
			hits = l
		}
		if strings.HasPrefix(l, "Bytes=") {
			bytes = l
		}
	}
	return hits, bytes
}

// TestGlobalCounterParallel は E059 の H1: 8 Thread × 200 の並行の test run で kernel の Hits=1600・Bytes=(1+…+8)×200 が双子と一致、Thread の区間が重なる。
func TestGlobalCounterParallel(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildThreadHarnessesFor(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "glob", "t_count.rb"), nil)
	s := countScript()
	tw, kn := feed(t, false, s, h.twin), feed(t, true, s, h.kernel)
	th, tb := globalLines(tw)
	kh, kb := globalLines(kn)
	t.Logf("twin %s %s, kernel %s %s, %v", th, tb, kh, kb, overlapLines(kn))
	if kh != "Hits=1600" || kh != th || kb != fmt.Sprintf("Bytes=%d", 36*200) || kb != tb {
		t.Errorf("want Hits=1600 and Bytes=7200 on both sides")
	}
	if strings.Contains(kn, "overlaps=0\n") {
		t.Errorf("the kernel threads did not overlap:\n%s", kn)
	}
}

// TestGlobalCounterMutant は E059 の H2 (対照): Hits の delta を 2 にした変異の kernel は Hits=3200 で双子と食い違う。
func TestGlobalCounterMutant(t *testing.T) {
	requireUnverified(t)
	h := buildThreadHarnessesFor(t, filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "glob", "t_count.rb"), replaceFirst("arith.constant 1 : i64", "arith.constant 2 : i64"))
	s := countScript()
	th, _ := globalLines(feed(t, false, s, h.twin))
	kh, _ := globalLines(feed(t, true, s, h.kernel))
	t.Logf("mutant: twin %s kernel %s", th, kh)
	if kh != "Hits=3200" || th != "Hits=1600" {
		t.Errorf("want the mutant kernel at Hits=3200 against the twin's 1600")
	}
}
