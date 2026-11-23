//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E010 の H4: 試験の build (tag spinelbpf_mutation) の hook の変異 — `go test -tags spinelbpf_mutation -run Hook ./cmd/spinelbpf`。

// TestHookNoOverflow は区間の証明の溢れの検査を外すと i64 の a + b が受理され、a = 2^63−1, b = 1 の行で twin (Spinel) は RangeError、
// kernel は wrap の −2^63 (map_get は ValueRange) — 表が不一致として落とす。
func TestHookNoOverflow(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "no-overflow")
	d := t.TempDir()
	src := filepath.Join(d, "t_hook.rb")
	os.WriteFile(src, []byte(hookProgram), 0o644)
	h := buildHarnesses(t, src)
	script := "reset\npoke In 0 9223372036854775807\npoke In 1 1\nrun prog\ndump\nreset\npoke In 0 3\npoke In 1 4\nrun prog\ndump\n"
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	t.Logf("twin:\n%s\nkernel:\n%s", tw, kn)
	rb := tw // CRuby の差動は一時的に外す (利用者の決定 2026-09-27 — SPINELBPF_CRUBY=1 で走らせる)
	if os.Getenv("SPINELBPF_CRUBY") == "1" {
		rb = feed(t, false, script, "ruby", "-I", filepath.Join(repoRoot(), "ruby", "lib", "native"), filepath.Join(filepath.Dir(h.twinBin), "t_hook.rb"))
	}
	r := compareTable(t, "t_hook", script, 2, tw, kn, rb)
	if len(r.spinelBad) == 0 && len(r.crubyBad) == 0 {
		t.Fatal("the unproven overflow was not caught by the table")
	}
	if !strings.Contains(tw, "err=RangeError") {
		t.Errorf("want the Spinel twin to raise RangeError on 2^63−1 + 1")
	}
	if !strings.Contains(kn, "Out[0]=err=SpinelBPF::ValueRange") {
		t.Errorf("want the kernel to wrap to −2^63 (ValueRange on map_get)")
	}
	if !strings.Contains(tw, "Out[0]=7") || !strings.Contains(kn, "Out[0]=7") {
		t.Errorf("the in-range row (3 + 4) must still agree")
	}
}

// TestHookSwapOperands は `-` と比較の operand の順を lower で入れ替えると、t_i32 の表で a − b と (a & M) − 1 の slot が、t_i32b で比較の slot が不一致になる。
func TestHookSwapOperands(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "swap-operands")
	h := buildHarnesses(t, tableSrc("t_i32"))
	os.Unsetenv("SPINELBPF_MUTATION")
	r := runTable(t, "t_i32", h)
	bad := append(r.spinelBad, r.crubyBad...)
	t.Logf("%d mismatching lines; first: %v", len(bad), first(bad, 3))
	for _, slot := range []string{"Out[1]", "O32[1]"} {
		hit := false
		for _, b := range bad {
			if strings.Contains(b, "\""+slot+"=") {
				hit = true
			}
		}
		if !hit {
			t.Errorf("no mismatch at %s (a − b / (a & M) − 1)", slot)
		}
	}
}

// TestHookSwapComparisons は同じ hook で t_i32b の比較の slot (a < b・a > b) が不一致になる。
func TestHookSwapComparisons(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "swap-operands")
	h := buildHarnesses(t, tableSrc("t_i32b"))
	os.Unsetenv("SPINELBPF_MUTATION")
	r := runTable(t, "t_i32b", h)
	bad := append(r.spinelBad, r.crubyBad...)
	for _, slot := range []string{"Out[23]", "Out[25]"} {
		hit := false
		for _, b := range bad {
			if strings.Contains(b, "\""+slot+"=") {
				hit = true
			}
		}
		if !hit {
			t.Errorf("no mismatch at %s", slot)
		}
	}
}
