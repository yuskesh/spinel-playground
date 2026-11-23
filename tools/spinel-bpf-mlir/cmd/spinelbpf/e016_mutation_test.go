//go:build spinelbpf_mutation

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E016 の H2 (M6・M7): hook `no-offset-range` (SB023 の検査を外す — 試験の build だけ) — `go test -tags spinelbpf_mutation -run TestHook ./cmd/spinelbpf`。

const hookNegVar = `require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 1)

def prog(ctx)
  e = ctx.check(0, 14)
  if e
    w = ctx.check(e.u8(0) - 20, 4)
    if w
      Out.update(0, w.u8(0))
    end
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
`

const hookNegConst = `require "bpf"

Out = BPF::ArrayMap.new("Out", :u64, 2)

def prog(ctx)
  w = ctx.check(-1, 4)
  if w
    Out.update(0, w.u8(0))
  else
    Out.update(1, 1)
  end
  BPF::XDP_PASS
end
BPF.xdp :prog
`

// TestHookNoOffsetRangeVariable は M6: 区間 [−20, 235] の offset を通すと、kernel の verifier が load を拒否する (検出器は verifier)。
func TestHookNoOffsetRangeVariable(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "no-offset-range")
	d := t.TempDir()
	src := filepath.Join(d, "t_negvar.rb")
	os.WriteFile(src, []byte(hookNegVar), 0o644)
	h := buildHarnesses(t, src)
	os.Unsetenv("SPINELBPF_MUTATION")
	cmd := sudoCmd(t, h.kernelBin)
	cmd.Stdin = strings.NewReader("reset\n")
	out, err := cmd.CombinedOutput()
	t.Logf("kernel harness load (root): err=%v %s", err, firstLines(string(out), 3))
	// 1 回目の観察 (予測の外): root の verifier は load を受理した。差動の行 — 先頭の byte (offset = byte − 20) が 20 未満の行は双子で offset が負 (nil)
	var script strings.Builder
	var negRows int
	for _, b0 := range []int{0, 5, 19, 20, 21, 30, 100, 255} {
		for _, n := range []int{14, 40, 64, 300} {
			if b0 < 20 {
				negRows++
			}
			script.WriteString("reset\nrun prog " + hexOf(frame(n, b0, map[int]int{0: b0})) + "\ndump\n")
		}
	}
	tw := feed(t, false, script.String(), h.twinBin)
	kn := feed(t, true, script.String(), h.kernelBin)
	rb := crubyFeed(t, script.String(), h)
	t.Logf("rows %d (negative offset in the twin: %d) — twin == kernel: %v, twin == CRuby: %v", 32, negRows, tw == kn, tw == rb)
	if tw != rb {
		t.Errorf("twin and CRuby differ")
	}
	if tw != kn {
		t.Logf("--- twin\n%s\n--- kernel\n%s", tw, kn)
	}
}

// TestHookNoOffsetRangeConstant は M7: 定数 −1 の offset を通すと、kernel は out_of_range、双子も nil — 差動では検出されない (P004 §5 の予告)。
func TestHookNoOffsetRangeConstant(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	t.Setenv("SPINELBPF_MUTATION", "no-offset-range")
	d := t.TempDir()
	src := filepath.Join(d, "t_negconst.rb")
	os.WriteFile(src, []byte(hookNegConst), 0o644)
	// 1 回目の観察 (予測の外): 差動まで届かず、ebpf-compile の op の verifier が定数の −1 (zero 拡張で 2^64 − 1) を MAX_PACKET_OFF の外として拒否する
	cfg, _ := defaultConfig()
	_, err := Build(cfg, src)
	os.Unsetenv("SPINELBPF_MUTATION")
	if err == nil || !strings.Contains(err.Error(), "exceeds MAX_PACKET_OFF") || !strings.Contains(err.Error(), "t_negconst.rb:6:3") {
		t.Fatalf("want ebpf-compile to refuse the constant −1 offset at t_negconst.rb:6:3, got %v", err)
	}
	t.Logf("detector ebpf-compile: %s", firstLines(err.Error(), 2))
}
