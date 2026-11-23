package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E048 の追補 (レビューの P2): library が Thread の持ち主の照合に使う Spinel の内部の関数 sp_Thread_current の 3 つの性質を固定する —
// Thread 無しの program は 0、Thread 有りは Thread ごとに 0 でない違う値、同じ Thread の中は同じ値。Spinel を上げた時に黙って変われば落ちる。

// currentProps は probe の出力 (nothr・thr) が 3 つの性質を満たすかを返す (満たさなければ理由)。
func currentProps(nothr, thr string) error {
	if !strings.Contains(nothr, "main=0 again=0") {
		return fmt.Errorf("without threads sp_Thread_current is not 0: %q", nothr)
	}
	var main, again, after int64
	if _, err := fmt.Sscanf(strings.SplitN(thr, "\n", 2)[0], "main=%d again=%d", &main, &again); err != nil || main == 0 || main != again {
		return fmt.Errorf("the main thread value is 0 or unstable: %q", thr)
	}
	seen := map[int64]bool{main: true}
	n := 0
	for _, l := range strings.Split(thr, "\n") {
		var i int
		var a, b int64
		if _, err := fmt.Sscanf(l, "t%d first=%d second=%d", &i, &a, &b); err == nil {
			if a == 0 || a != b || seen[a] {
				return fmt.Errorf("thread %d: value 0, unstable across Thread.pass, or shared with another thread: %q", i, l)
			}
			seen[a] = true
			n++
		}
		if _, err := fmt.Sscanf(l, "main after=%d", &after); err == nil && after != main {
			return fmt.Errorf("the main thread value changed after the threads: %q", l)
		}
	}
	if n != 4 || after == 0 {
		return fmt.Errorf("want 4 thread lines and a main-after line, got %d:\n%s", n, thr)
	}
	return nil
}

// TestSpinelThreadCurrent は E048 の H6: 2 つの probe を spinel で直接 build して走らせ、3 つの性質。対照: 性質を壊した出力は currentProps が拒否する。
func TestSpinelThreadCurrent(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	out := map[string]string{}
	for _, p := range []string{"cur_nothr", "cur_thr"} {
		d := t.TempDir()
		b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "threads", p+".rb"))
		if err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(d, p+".rb"), b, 0o644)
		c := exec.Command(cfg.Spinel, p+".rb", "-o", p)
		c.Dir, c.Env = d, append(os.Environ(), "TMPDIR="+d)
		if o, err := c.CombinedOutput(); err != nil {
			t.Fatalf("building %s: %v\n%s", p, err, o)
		}
		o, err := exec.Command(filepath.Join(d, p)).CombinedOutput()
		if err != nil {
			t.Fatalf("running %s: %v\n%s", p, err, o)
		}
		out[p] = string(o)
	}
	t.Logf("nothr: %s\nthr:\n%s", out["cur_nothr"], out["cur_thr"])
	if err := currentProps(out["cur_nothr"], out["cur_thr"]); err != nil {
		t.Fatal(err)
	}
	// 対照: 3 つの性質を 1 つずつ壊した出力
	lines := strings.Split(out["cur_thr"], "\n")
	var t1a string
	fmt.Sscanf(lines[1], "t0 first=%s", &t1a)
	for name, bad := range map[string][2]string{
		"nonzero without threads": {"main=7 again=7", out["cur_thr"]},
		"unstable in a thread":    {out["cur_nothr"], strings.Replace(out["cur_thr"], "second="+strings.Fields(lines[1])[1][len("first="):], "second=1", 1)},
		"shared between threads":  {out["cur_nothr"], strings.Replace(out["cur_thr"], lines[2], "t1 first="+strings.Fields(lines[1])[1][len("first="):]+" second="+strings.Fields(lines[1])[1][len("first="):], 1)},
	} {
		if currentProps(bad[0], bad[1]) == nil {
			t.Errorf("control %q: currentProps accepted a broken output", name)
		}
	}
}
