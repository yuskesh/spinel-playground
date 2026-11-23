package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// E049 の試験 (P012 — host、root): user 空間の Thread の範囲 — map と test run は並行・load は main・ring の reader は持ち主・
// object の close の競合は bml の STATE・長い ring の read の間の GC の待ちは区切りで短い。driver は testdata/threads/scope.rb。

var (
	scopeOnce sync.Once
	scopeExe  string
	scopeErr  error
)

func scopeDriver(t *testing.T) string {
	t.Helper()
	scopeOnce.Do(func() {
		cfg, err := defaultConfig()
		if err != nil {
			scopeErr = err
			return
		}
		d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e049-")
		if err != nil {
			scopeErr = err
			return
		}
		b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "threads", "scope.rb"))
		if err != nil {
			scopeErr = err
			return
		}
		src := filepath.Join(d, "scope.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			scopeErr = err
			return
		}
		scopeExe = filepath.Join(d, "scope")
		scopeErr = Link(cfg, src, scopeExe)
	})
	if scopeErr != nil {
		t.Fatal(scopeErr)
	}
	return scopeExe
}

func scopeRun(t *testing.T, args ...string) string {
	t.Helper()
	out, err := sudo(t, append([]string{scopeDriver(t)}, args...)...)
	if err != nil {
		t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return out
}

// TestThreadParallel は E049 の H3: 8 Thread の map_put / map_get と 4 Thread の test_run_xdp を同時に — 誤り 0・合計 400。
func TestThreadParallel(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	out := scopeRun(t, "par")
	for i := 0; i < 8; i++ {
		if !strings.Contains(out, fmt.Sprintf("w%d bad=0\n", i)) {
			t.Errorf("writer %d saw a wrong value:\n%s", i, out)
		}
	}
	if strings.Count(out, "ret=2\n") != 4 || !strings.Contains(out, "counts0=400\n") {
		t.Errorf("want 4 runners returning XDP_PASS and Counts[0]=400:\n%s", out)
	}
}

// TestThreadLoadMainOnly は E049 の H4: Thread の中の load は State、4 Thread が回る間の main の load と close は 20 回とも成功。
func TestThreadLoadMainOnly(t *testing.T) {
	requireUnverified(t)
	if out := scopeRun(t, "load_thread"); !strings.Contains(out, "load kind=SpinelBPF::State msg=SpinelBPF.load_embedded: load from the main Thread only") {
		t.Errorf("a load from a Thread should be refused:\n%s", out)
	}
	if out := scopeRun(t, "load_busy"); !strings.Contains(out, "loads ok=20") {
		t.Errorf("want 20 main-thread loads while threads run:\n%s", out)
	}
}

// TestThreadRingOwner は E049 の H5: main が開いた reader を別の Thread が read / close すると State、持ち主の read と close は今どおり。
func TestThreadRingOwner(t *testing.T) {
	requireUnverified(t)
	out := scopeRun(t, "ring_other")
	for _, w := range []string{
		"read kind=SpinelBPF::State msg=RingReader#read_record: the ring buffer reader belongs to the Thread that opened it",
		"close kind=SpinelBPF::State msg=RingReader#close: the ring buffer reader belongs to the Thread that opened it",
		"owner read=0", "owner close ok",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("want %q:\n%s", w, out)
		}
	}
}

// TestThreadCloseInFlight は E049 の H6: 別の Thread の ring の read の最中の object の close は bml の STATE (in-flight の文)、join の後の close は OK。
// 区切りの間に close が入る結果 (close が先に成功し read の Thread が State) も loud — 20 回の 2 つの結果の数を記録し、他の結果は 0。
func TestThreadCloseInFlight(t *testing.T) {
	requireUnverified(t)
	out := scopeRun(t, "close_busy")
	t.Log(strings.TrimSpace(out))
	var refused, first int
	for _, l := range strings.Split(out, "\n") {
		fmt.Sscanf(l, "refused=%d closed_first=%d", &refused, &first)
	}
	if refused+first != 20 || refused == 0 || !strings.Contains(out, "calls in flight on other threads — close it again after they return") {
		t.Errorf("want 20 loud outcomes with at least one in-flight refusal:\n%s", out)
	}
	if first > 0 && strings.Count(out, "close ok first; reader kind=SpinelBPF::State") != first {
		t.Errorf("a close that went first must leave the reading Thread with a State:\n%s", out)
	}
}

// TestThreadGCStall は E049 の H7: 別の Thread の 5 s の ring の read (event 無し) の間の main の反復の最大の間隔 — 区切り (100 ms) の前は約 5 s だった。
// 閾は 1 s (gate の並行の揺らぎに耐える — 測った値は E049 の Edoc: 101〜104 ms)。
func TestThreadGCStall(t *testing.T) {
	requireUnverified(t)
	out := scopeRun(t, "gc", "5000")
	var read, gap int
	for _, l := range strings.Split(out, "\n") {
		fmt.Sscanf(l, "read=%d maxgap_ms=%d", &read, &gap)
	}
	t.Logf("max gap %d ms", gap)
	if gap == 0 || gap > 1000 {
		t.Errorf("want the other Thread's longest pause under 1 s during a 5 s ring read, got %d ms:\n%s", gap, out)
	}
}
