package frontend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTpBtfHarnessStops は E086 の H5 を E087 で改めた形: TwinHarness・KernelHarness は tp_btf の形 (双子の TpBtfCtx・kernel の attach_tp_btf と
// fork の命令) を作り、Thread の変種と E005 の NativeTwin は名指し (E087) で止まる。
func TestTpBtfHarnessStops(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join("testdata", "pos", "tpbtf_fork.rb")
	text, _ := os.ReadFile(f)
	res, err := Analyze(sp, t.TempDir(), f, string(text))
	if err != nil || len(res.Programs) == 0 {
		t.Fatalf("analyze: %v", err)
	}
	for what, gen := range map[string]func(string, *Result) (string, error){
		"NativeTwin": NativeTwin, "TwinHarnessThreads": TwinHarnessThreads, "KernelHarnessThreads": KernelHarnessThreads,
	} {
		if _, err := gen(string(text), res); err == nil || !strings.Contains(err.Error(), "tp_btf") || !strings.Contains(err.Error(), "are not written here") {
			t.Errorf("%s: want the named tp_btf stop, got %v", what, err)
		}
	}
	tw, err := TwinHarness(string(text), res)
	if err != nil || !strings.Contains(tw, "_h_ks = [_h_kp0, _h_kp1]\n") || !strings.Contains(tw, "on_fork(BPF::TpBtfCtx.new(_h_ks, [0, 1], _h_ints))") { // E088: 引数の並びは _h_ks (nullable の引数を nil に)
		t.Errorf("TwinHarness: want the tp_btf form, got err %v", err)
	}
	kh, err := KernelHarness(string(text), res)
	if err != nil || !strings.Contains(kh, `_h_obj.attach_tp_btf("on_fork")`) {
		t.Errorf("KernelHarness: want the tp_btf form, got err %v", err)
	}
}
