//go:build spinelbpf_mutation

package main

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestHookSfMutations は E126 の H7 (a)(b) (host、root): 変異の対照の検出器の列 — 各々で双子と kernel の出力が食い違い、最初の食い違いが意図した行に在り、
// その行の中身に印の文字列がある。sf-len-l2 は harness の双子 (len を eth を外さない n に)、sf-ge は frontend の比べ (`>` を `>=` に — kernel の側の ELF だけ)。
func TestHookSfMutations(t *testing.T) {
	requireUnverified(t)
	script := tSfScript()
	for _, m := range []struct {
		name, hook string
		row, line  string
	}{
		{"len-l2 (双子の len を eth を外さない n に)", "sf-len-l2", "s_bounds", "Out[0]="},
		{"ge (> を >= に)", "sf-ge", "s_bounds", "ret="},
	} {
		t.Setenv("SPINELBPF_MUTATION", m.hook)
		h := buildHarnesses(t, sfData("t_sf.rb"))
		os.Unsetenv("SPINELBPF_MUTATION")
		tw := feed(t, false, script, h.twinBin)
		kn := feed(t, true, script, h.kernelBin)
		d := ringDiff(tw, kn)
		t.Logf("%s: %s", m.name, d)
		if d == "" || !strings.HasPrefix(d, "row "+m.row+" ") || !strings.Contains(d, "\""+m.line) {
			t.Errorf("%s: want the first difference at row %s on %q, got %q", m.name, m.row, m.line, d)
		}
	}
}

// TestHookSfSwapVerdict は E126 の H7 (c) (host、root、自分の socket だけ): frontend が keep と drop を入れ替えると、実の attach で受ける datagram が 65〜200 の
// 136 個になる (sfattach.want と違う — 変異が実の socket の振る舞いに届く)。
func TestHookSfSwapVerdict(t *testing.T) {
	requireUnverified(t)
	t.Setenv("SPINELBPF_MUTATION", "sf-swap-verdict")
	exe := buildDataProgram(t, sfData("sfattach.rb"), lpmConfig(t))
	os.Unsetenv("SPINELBPF_MUTATION")
	out := feed(t, true, "", exe)
	var lens []string
	for n := 65; n <= 200; n++ {
		lens = append(lens, strconv.Itoa(n))
	}
	want := "attached\nsent=200 got=136\nlens=" + strings.Join(lens, ",") + "\nout=200\n"
	if out != want {
		t.Errorf("swapped verdicts: got\n%s\nwant\n%s", out, want)
	}
}
