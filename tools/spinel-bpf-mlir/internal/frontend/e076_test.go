package frontend

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestSchedClsHarnessStops は E076 の H4 を E077 で改めた形: sched_cls の program の在る source の TwinHarness・KernelHarness は sched_cls の形
// (双子は BPF::SkBuff、kernel は test_run_tc_packet) を作り xdp の形を作らない。Thread の変種と E005 の NativeTwin は名指しで止まる
// (黙って xdp の形 — XdpMd・test_run_xdp — を作らない)。xdp と共有の source (tc_xdp_shared) でも同じ。
func TestSchedClsHarnessStops(t *testing.T) {
	sp := testSpinel(t)
	for _, name := range []string{"tc_ingress", "tc_xdp_shared"} {
		f := filepath.Join("testdata", "pos", name+".rb")
		text, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		res, err := Analyze(sp, t.TempDir(), f, string(text))
		if err != nil || len(res.Programs) == 0 {
			t.Fatalf("%s: analyze: %v", name, err)
		}
		for what, gen := range map[string]func(string, *Result) (string, error){
			"NativeTwin": NativeTwin, "TwinHarnessThreads": TwinHarnessThreads, "KernelHarnessThreads": KernelHarnessThreads,
		} {
			out, err := gen(string(text), res)
			if err == nil || !strings.Contains(err.Error(), "no sched_cls form") {
				t.Errorf("%s %s: want a named stop, got err %v (output %d bytes)", name, what, err, len(out))
			}
		}
		tc := res.Programs[len(res.Programs)-1].Name // tc の root は各 file の最後の宣言
		for what, c := range map[string]struct {
			gen       func(string, *Result) (string, error)
			want, not string
		}{
			"TwinHarness":   {TwinHarness, tc + "(BPF::SkBuff.new(", tc + "(BPF::XdpMd.new("},
			"KernelHarness": {KernelHarness, "_h_obj.test_run_tc_packet(\"" + tc + "\"", "_h_obj.test_run_xdp(\"" + tc + "\""},
		} {
			out, err := c.gen(string(text), res)
			if err != nil || !strings.Contains(out, c.want) || strings.Contains(out, c.not) {
				t.Errorf("%s %s: want the sched_cls form %q and not %q, got err %v", name, what, c.want, c.not, err)
			}
		}
	}
}
