package main

import (
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// E065 の試験: builtin の method と名前の衝突する record の member (b・bytes・first) の読みを operator の receiver にした program の双子と kernel の差動
// (双子の native の実行が poly の receiver の `.bytes` 等を String#bytes 等でなく record の getter に dispatch すること — レビュー役の条件 (2))。

// TestRecordMemberBuiltinNames は E065 の H2 (root): member の値の行ごとに双子と kernel の dump が一致し、双子に err= が無い。
func TestRecordMemberBuiltinNames(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h := buildHarnesses(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "rec_member_builtin_names.rb"))
	var b strings.Builder
	rows := 0
	for _, v := range []string{"0", "1", "255", "256", "65535", "4294967295"} {
		for _, w := range []string{"0", "7", "65536", "4294967301"} {
			fmt.Fprintf(&b, "echo r%d\nreset\npoke Ns 0 b %s\npoke Ns 0 bytes %s\npoke Ns 0 first %s\npoke Stats 1 bytes %s\npoke Stats 1 hits %s\nrun prog\ndump\n", rows, v, v, v, w, w)
			rows++
		}
	}
	script := b.String()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if strings.Contains(tw, "err=") || strings.Contains(kn, "err=") {
		t.Fatalf("an error line — twin:\n%s\nkernel:\n%s", tw, kn)
	}
	d := loopDiff(t, tw, kn, rows)
	for i, s := range d {
		t.Errorf("row %d: twin and kernel differ in %v", i, keysOf(s))
	}
	t.Logf("%d rows, %d differing", rows, len(d))
	if !strings.Contains(tw, "Out[1]=16") { // 256 >> 4 の行が在る (値が実際に流れた)
		t.Errorf("the twin never produced Out[1]=16:\n%s", tw)
	}
}
