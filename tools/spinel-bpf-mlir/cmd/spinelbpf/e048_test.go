package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E048 の試験 (P012): Thread を使わない program は Spinel の threaded runtime を持たない (library が Thread 等の定数を参照すると
// 全ての program が threaded になる — E049 で library を変える前の固定)。

// TestNoThreadedRuntime は E048 の H4: 例 6 つの実行 file (既定の build) に threaded runtime の symbol (sp_sched_init — threaded の main が呼ぶ) と pthread_create が無い
// (sp_sched_ensure_workers は static で nm に出ず、Thread 有りでも落ちえない — 着手中に対照で見つけて外した)。
// 対照: Thread を使う probe (results/E048/current/cur_thr.rb) の実行 file には両方が在る (E048 の手順 3)。
func TestNoThreadedRuntime(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	for _, n := range []string{"xdpcount", "ethertype", "lastseen", "pktlog", "flowcount", "protostat"} {
		d := t.TempDir()
		b, err := os.ReadFile(filepath.Join(repoRoot(), "examples", n, n+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		src := filepath.Join(d, n+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		exe := filepath.Join(d, n)
		if err := Link(cfg, src, exe); err != nil {
			t.Fatalf("%s: %v", n, err)
		}
		syms, err := exec.Command("nm", exe).Output()
		if err != nil {
			t.Fatal(err)
		}
		for _, s := range []string{"sp_sched_init", "pthread_create"} {
			if strings.Contains(string(syms), s) {
				t.Errorf("%s: the executable carries %s (threaded runtime)", n, s)
			}
		}
	}
}
