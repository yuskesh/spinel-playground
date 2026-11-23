package frontend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestKeptSourceMultiline は E103: 複数行の宣言 (Struct.new・BPF.record・RingBuf.new の引数を改行で分けた形) を双子の harness の source が
// 閉じ括弧の行まで写す (1 回目は最初の行だけを写し、双子の Spinel の parse が落ちた)。
func TestKeptSourceMultiline(t *testing.T) {
	sp := testSpinel(t)
	src := `require "bpf"

Ev = Struct.new(:a,
  :b,
  :c)
BPF.record(Ev, a: :u64,
  b: :u64,
  c: :u64)
Evs = BPF::RingBuf.new("Evs", Ev.new(0,
  0,
  0), 4096)

def prog(ctx)
  if Evs.output(Ev.new(1,
    2,
    3))
    return BPF::XDP_PASS
  end
  BPF::XDP_DROP
end
BPF.xdp :prog
`
	d := t.TempDir()
	f := filepath.Join(d, "ml.rb")
	os.WriteFile(f, []byte(src), 0o644)
	res, err := Analyze(sp, t.TempDir(), f, src)
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := TwinHarness(src, res)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Ev = Struct.new(:a,\n  :b,\n  :c)\n", "BPF.record(Ev, a: :u64,\n  b: :u64,\n  c: :u64)\n", "Evs = BPF::RingBuf.new(\"Evs\", Ev.new(0,\n  0,\n  0), 4096)\n"} {
		if !strings.Contains(tw, want) {
			t.Errorf("the twin harness source lacks the whole declaration %q", want)
		}
	}
	if parenDelta("a(b, \"(\", c) # (") != 0 || parenDelta("x = f(") != 1 {
		t.Errorf("parenDelta counts parens inside strings or comments")
	}
}
