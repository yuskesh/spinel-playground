package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E153 の試験 (P029 §2 段 1 — tracepoint の固定 byte の配列の field、bpf-mlir E552): 生成物 (H1)・双子の smoke・sock/inet_sock_set_state の
// 自分の loopback の connect の差動 (H3 — root、Filter の窓、予約と借用の 2 つの program)。負の例 (H2 — 追補 3) は internal/frontend の
// testdata/neg の tpa_*.rb (TestNegative)、変異 tp-copy-drop (追補 1) は e153_mutation_test.go。

func tpArraySrc(form string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "trace_tp_array_"+form+".rb")
}

// tpArrayBytes は 4 / 16 byte の hex (双子と kernel の event の配列の member の印字の形)。
var (
	tpLoop4      = "7f000001"
	tpLoop4Zero  = "00000000"
	tpMapped6    = "00000000000000000000ffff7f000001" // v4 の socket の daddr_v6 — kernel の TP_STORE_V4MAPPED (net_probe_common.h)
	tpLoop6      = "00000000000000000000000000000001"
	tpLoop4Bytes = "127,0,0,1"
	tpMapped6B   = "0,0,0,0,0,0,0,0,0,0,255,255,127,0,0,1"
	tpLoop6B     = "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1"
	tpZero4B     = "0,0,0,0"
)

// TestTpArrayArtefacts は H1: .mlir の ebpf.tp.field.copy (予約と借用)、schema の {kind: array, elem: u8, n: N}、requirements の形式 17 と tpfield [N]u8。
func TestTpArrayArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	for _, form := range []string{"ring", "borrow"} {
		d := t.TempDir()
		b, _ := os.ReadFile(tpArraySrc(form))
		name := "trace_tp_array_" + form
		src := filepath.Join(d, name+".rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatalf("%s: %v", form, err)
		}
		m, _ := os.ReadFile(filepath.Join(d, name+".mlir"))
		dst := map[string]string{"ring": "!ebpf.reservation<", "borrow": "!ebpf.borrowed<"}[form]
		for _, w := range []string{`ebpf.tp.field.copy`, `"daddr", %ctx "daddr" [36] : ` + dst, `"daddr_v6", %ctx "daddr_v6" [56] : ` + dst} {
			if !strings.Contains(string(m), w) {
				t.Errorf("%s: .mlir lacks %q", form, w)
			}
		}
		s, _ := os.ReadFile(filepath.Join(d, name+".schema.json"))
		for _, w := range []string{`"kind": "array",`, `"elem": "u8",`, `"n": 4`, `"n": 16`} {
			if !strings.Contains(string(s), w) {
				t.Errorf("%s: schema lacks %q", form, w)
			}
		}
		r := elfRequirements(t, cfg, filepath.Join(d, name+".bpf.o"))
		for _, w := range []string{"ebpf-requirements 17\n", "tpfield\ton_state\tdaddr\t36\t4\t[4]u8\n", "tpfield\ton_state\tdaddr_v6\t56\t16\t[16]u8\n"} {
			if !strings.Contains(string(r), w) {
				t.Errorf("%s: requirements lack %q:\n%s", form, w, r)
			}
		}
	}
}

// TestTpArrayTwinSmoke は双子の smoke: harness の f=b0,b1,… の byte が event の配列の member に、書かない field は 0。
func TestTpArrayTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "trace_tp_array_ring")
	out := feed(t, false, "reset\npoke Filter 0 4242\ntask 18219251273881\nrun on_state protocol=6 oldstate=7 newstate=2 family=2 dport=4567 daddr="+tpLoop4Bytes+" daddr_v6="+tpMapped6B+"\nrun on_state protocol=6 oldstate=7 newstate=2 family=10 dport=4568 daddr_v6="+tpLoop6B+"\ndrain Events\n", tw)
	t.Log(out)
	wantLines(t, out, "Events#0.family=2", "Events#0.dport=4567", "Events#0.daddr="+tpLoop4, "Events#0.daddr_v6="+tpMapped6,
		"Events#1.family=10", "Events#1.daddr="+tpLoop4Zero, "Events#1.daddr_v6="+tpLoop6, "Events drained=2")
}

// tpArrayDiff は H3 の 2 段の差動 (E142 と同じ窓): kernel は Filter に自分の tgid を書いた直後に v4 と v6 の自分の loopback の connect を各 3 回、
// 直後に Filter を 0 に。双子は同じ tgid・tid と port で、byte は kernel の規則 (v4 の daddr_v6 は v4-mapped、v6 の daddr は 0 — 背景) を harness に写す。
func tpArrayDiff(t *testing.T, h harnessSet, prog, out string) (kernel, twin string) {
	t.Helper()
	kernel = feed(t, true, "reset\nself\npokeself Filter 0\ntcpconnect 4 3\ntcpconnect 6 3\npoke Filter 0 0\n"+out+"dump\n", h.kernelBin)
	var tgid int64
	var tids, ports []int64
	for _, l := range strings.Split(kernel, "\n") {
		fmt.Sscanf(l, "tgid=%d", &tgid)
		var v int64
		if _, err := fmt.Sscanf(l, "tid=%d", &v); err == nil {
			tids = append(tids, v)
		}
		if _, err := fmt.Sscanf(l, "port=%d", &v); err == nil {
			ports = append(ports, v)
		}
	}
	if tgid == 0 || len(tids) != 2 || len(ports) != 6 {
		t.Fatalf("want tgid, 2 tids and 6 ports in the kernel harness output:\n%s", kernel)
	}
	var ts strings.Builder
	ts.WriteString(fmt.Sprintf("reset\npoke Filter 0 %d\n", tgid))
	for i, p := range ports {
		fam, tid, bytes := "family=2 daddr="+tpLoop4Bytes+" daddr_v6="+tpMapped6B, tids[0], ""
		if i >= 3 {
			fam, tid = "family=10 daddr="+tpZero4B+" daddr_v6="+tpLoop6B, tids[1]
		}
		ts.WriteString(fmt.Sprintf("task %d\nrun %s protocol=6 oldstate=7 newstate=2 dport=%d %s%s\n", tgid<<32|tid, prog, p, fam, bytes))
	}
	ts.WriteString("poke Filter 0 0\n" + out + "dump\n")
	twin = feed(t, false, ts.String(), h.twinBin)
	return
}

// TestTpArrayDifferential は H3 (root): 予約 (ring) の program は event がちょうど 6 つ (v4 3 — daddr 127.0.0.1・daddr_v6 v4-mapped、
// v6 3 — daddr_v6 ::1・daddr 0)、借用 (borrow) の program は Last[0] が最後の v6 の event と同じ、どちらも drain の行と dump が双子と byte 同じ。
func TestTpArrayDifferential(t *testing.T) {
	requireUnverified(t)
	for _, c := range []struct{ form, out string }{{"ring", "drain Events\n"}, {"borrow", ""}} {
		h := buildHarnesses(t, tpArraySrc(c.form))
		k, w := tpArrayDiff(t, h, "on_state", c.out)
		t.Logf("%s kernel:\n%s", c.form, k)
		if c.form == "ring" {
			kr, wr := ringLines(k), ringLines(w)
			if strings.Join(kr, "\n") != strings.Join(wr, "\n") {
				t.Errorf("ring events differ\nkernel:\n%s\ntwin:\n%s", strings.Join(kr, "\n"), strings.Join(wr, "\n"))
			}
			wantLines(t, k, "Events#0.daddr="+tpLoop4, "Events#0.daddr_v6="+tpMapped6, "Events#3.daddr="+tpLoop4Zero, "Events#3.daddr_v6="+tpLoop6, "Events drained=6", "Out[0]=6")
		} else {
			wantLines(t, k, "Out[0]=6")
		}
		sameDump(t, "tracepoint byte array "+c.form, k, w)
	}
}

// E153 の H5 / H6 (P029 — tracepoint の配列の field の tool)。
func TestBccSelftestTcpconnect(t *testing.T) { bccSelftest(t, "bcc/tcpconnect") }
func TestBccSelftestTcpaccept(t *testing.T)  { bccSelftest(t, "bcc/tcpaccept") }
