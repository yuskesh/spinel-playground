package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E154 の試験 (P029 §2 段 2a — kernel の struct の埋め込みの経路、bpf-mlir E553): 生成物 (H1)・双子の smoke・fentry tcp_sendmsg の sock の __sk_common の
// 差動 (H4 — root、Filter の窓)。負の例 (H3 — 追補 3・4) は internal/frontend の testdata/neg の kps_* / kpu_* (TestNegative)、変異 kpath-flat は
// e154_mutation_test.go、tcpretrans の selftest は TestBccSelftestTcpretrans。

func kpathSrc(name string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb")
}

// TestKpathArtefacts は H1: .mlir の kfield.load の経路、schema の {kind: struct, struct: …}、requirements の形式 17 と途中の証拠と leaf の行。
func TestKpathArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	for _, c := range []struct {
		name  string
		mlir  []string
		reqs  []string
		types []string
	}{
		{"trace_kpath_sock", []string{`ebpf.kfield.load %v1 "__sk_common.skc_daddr" : !ebpf.kptr<"sock"> -> i32`, `"__sk_common.skc_dport" : !ebpf.kptr<"sock"> -> i16`, `"__sk_common.skc_num"`},
			[]string{"ebpf-requirements 17\n", "kfield\ton_send\tsock\t__sk_common\tstruct:sock_common\n", "kfield\ton_send\tsock\t__sk_common.skc_daddr\tu32\n", "kfield\ton_send\tsock\t__sk_common.skc_dport\tu16\n"},
			[]string{`"kind": "struct",`, `"struct": "sock_common"`}},
		{"trace_kpath_three", []string{`ebpf.kfield.load %v1 "mid.inner.v" : !ebpf.kptr<"e154_outer"> -> i32`},
			[]string{"kfield\ton_x\te154_outer\tmid\tstruct:e154_mid\n", "kfield\ton_x\te154_outer\tmid.inner\tstruct:e154_inner\n", "kfield\ton_x\te154_outer\tmid.inner.v\tu32\n"},
			[]string{`"struct": "e154_mid"`, `"struct": "e154_inner"`}},
	} {
		d := t.TempDir()
		b, _ := os.ReadFile(kpathSrc(c.name))
		src := filepath.Join(d, c.name+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		m, _ := os.ReadFile(filepath.Join(d, c.name+".mlir"))
		for _, w := range c.mlir {
			if !strings.Contains(string(m), w) {
				t.Errorf("%s: .mlir lacks %q", c.name, w)
			}
		}
		s, _ := os.ReadFile(filepath.Join(d, c.name+".schema.json"))
		for _, w := range c.types {
			if !strings.Contains(string(s), w) {
				t.Errorf("%s: schema lacks %q", c.name, w)
			}
		}
		r := elfRequirements(t, cfg, filepath.Join(d, c.name+".bpf.o"))
		for _, w := range c.reqs {
			if !strings.Contains(string(r), w) {
				t.Errorf("%s: requirements lack %q:\n%s", c.name, w, r)
			}
		}
	}
}

// kpathKernelValues は kernel の sock_common の field の値 (127.0.0.2・listen の port は network order — little endian の u32 / u16 として読む、
// skc_num は host order の client の port)。双子の harness に写す kernel の規則 (H4 — 名指し)。
func kpathKernelValues(port, cport int64) (daddr, dport, num int64) {
	return 0x0200007f, (port&0xff)<<8 | port>>8, cport
}

// TestKpathTwinSmoke は双子の smoke: harness の a0.__sk_common.<m> が経路の読みに届く。
func TestKpathTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_kpath_sock")
	da, dp, n := kpathKernelValues(4567, 51000)
	out := feed(t, false, fmt.Sprintf("reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_send a0.__sk_common.skc_daddr=%d a0.__sk_common.skc_dport=%d a0.__sk_common.skc_num=%d\ndrain Events\n", da, dp, n), tw)
	t.Log(out)
	wantLines(t, out, fmt.Sprintf("Events#0.daddr=%d", da), fmt.Sprintf("Events#0.dport=%d", dp), "Events#0.sport=51000", "Events drained=1")
}

// kpathDiff は H4 の 2 段の差動 (E142 と同じ窓): kernel は Filter に自分の tgid を書いた直後に tcpsend を 3 回、直後に Filter を 0 に。
// 双子は同じ tgid・tid と、kernel の field の値 (kpathKernelValues)。
func kpathDiff(t *testing.T, h harnessSet) (kernel, twin string) {
	t.Helper()
	kernel = feed(t, true, "reset\nself\npokeself Filter 0\ntcpsend 3\npoke Filter 0 0\ndrain Events\ndump\n", h.kernelBin)
	var tgid, tid int64
	var ports, cports []int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tgid=%d", &tgid)
		fmt.Sscanf(l, "tid=%d", &tid)
		var v int64
		if _, err := fmt.Sscanf(l, "port=%d", &v); err == nil {
			ports = append(ports, v)
		}
		if _, err := fmt.Sscanf(l, "cport=%d", &v); err == nil {
			cports = append(cports, v)
		}
	}
	if tgid == 0 || tid == 0 || len(ports) != 3 || len(cports) != 3 {
		t.Fatalf("want tgid, tid, 3 ports and 3 client ports in the kernel harness output:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString(fmt.Sprintf("reset\npoke Filter 0 %d\n", tgid))
	for i := range ports {
		da, dp, n := kpathKernelValues(ports[i], cports[i])
		ts.WriteString(fmt.Sprintf("task %d\nrun on_send a0.__sk_common.skc_daddr=%d a0.__sk_common.skc_dport=%d a0.__sk_common.skc_num=%d\n", tgid<<32|tid, da, dp, n))
	}
	ts.WriteString("poke Filter 0 0\ndrain Events\ndump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestKpathDifferential は H4 (root): event がちょうど 3 つ (daddr 127.0.0.2・dport と sport は listen と client の port)、drain の行と dump が双子と byte 同じ。
func TestKpathDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, kpathSrc("trace_kpath_sock"))
	k, w := kpathDiff(t, h)
	t.Log(k)
	kr, wr := ringLines(k), ringLines(w)
	if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
		t.Errorf("ring events differ\nkernel:\n%s\ntwin:\n%s", strings.Join(kr, "\n"), strings.Join(wr, "\n"))
	}
	wantLines(t, k, "Events#0.daddr=33554559", "Events drained=3", "Out[0]=3")
	sameDump(t, "kernel struct member path", k, w)
}

// E154 の H5 (P029 — 埋め込みの経路の tool)。
func TestBccSelftestTcpretrans(t *testing.T) { bccSelftest(t, "bcc/tcpretrans") }
