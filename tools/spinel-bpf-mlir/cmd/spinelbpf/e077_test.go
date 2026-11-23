package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E077 の試験 (P019): sched_cls の user 空間 (attach_tcx・tcx_direction・test_run_tc_packet)・非 root・双子と kernel の harness の smoke。

// TestTcAttachKind は E077 の H1〜H3 と H6: 利用者の program (testdata/tc/attach_kind.rb) を root と非 root で走らせ出力の行を見る。
// host の lo に pass だけの tcx の program を短く attach する — 独占 (P018 の類 d: 名前の固定の資源 — 他の試験と同時に lo を触らない)。
func TestTcAttachKind(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, err := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tc", "attach_kind.rb"))
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, "attach_kind.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "attach_kind")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"load ok unmet=0",                 // H1: requirements の tcx の行は Unknown にならない
		"dir tc_in=ingress tc_out=egress", // H1: kernel の link の info の向き
		"detached",                        // H1: detach の 2 回目も OK
		"xdp as tcx kind=SpinelBPF::State msg=",
		"tc as xdp kind=SpinelBPF::State msg=",
		"no if kind=SpinelBPF::Other msg=",
		"zero64 ret=0", "counted 1", // H3: TC_PASS (0) と map の数え
		"byte256 err=SpinelBPF::ValueRange msg=spinelbpf: packet byte 5 is 256, outside 0..255",
		"len13 err=SpinelBPF::Other msg=bml: tc test run tc_in with 13 bytes: invalid argument",
		"ipv4_33 err=SpinelBPF::Other msg=bml: tc test run tc_in with 33 bytes: invalid argument",
		"ipv4_34 ret=0",
		"ipv6_53 err=SpinelBPF::Other msg=bml: tc test run tc_in with 53 bytes: invalid argument",
		"ipv6_54 ret=0",
	}
	check := func(who, out string) {
		lines := strings.Split(strings.TrimSpace(out), "\n")
		if len(lines) != len(want) {
			t.Errorf("%s: want %d lines, got %d:\n%s", who, len(want), len(lines), out)
			return
		}
		for i, w := range want {
			if !strings.HasPrefix(lines[i], w) {
				t.Errorf("%s: line %d: want prefix %q, got %q", who, i+1, w, lines[i])
			}
		}
	}
	check("root", feed(t, true, "", exe))
	// H6: uid 1000 の CAP_BPF + CAP_NET_ADMIN で同じ出力、CAP_BPF だけでは load の前の照合 (sched_cls の probe) が EPERM で止まる
	out, err := nonroot(t, "+bpf,+net_admin", "", exe)
	if err != nil {
		t.Errorf("non-root +bpf,+net_admin: %v\n%s", err, out)
	}
	check("non-root +bpf,+net_admin", out)
	out, err = nonroot(t, "+bpf", "", exe)
	if err == nil || !strings.HasPrefix(out, "load err=SpinelBPF::") || !strings.Contains(out, "operation not permitted") {
		t.Errorf("non-root +bpf only: want a refused load (EPERM), got err %v\n%s", err, out)
	}
	t.Logf("+bpf only: %s", firstLines(out, 1))
}

// TestTcHarnessSmoke は E077 の H4 と H5: E076 の 3 つの tc の正の例の双子と kernel の harness (kernel は root の load — verifier の受理) が、同じ
// script (IPv4 34・IPv6 54・ARP 42・ethertype 0 の 64 byte と data 無しの run) で行ごとに同じ出力。egress の guard は IPv6 で drop (2)、
// xdp と共有の例は xdp が XDP_PASS (2)・sched_cls が TC_PASS (0) で同じ map を数える。
func TestTcHarnessSmoke(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	frames := []struct {
		name string
		f    []int
	}{
		{"ipv4", frame(34, 1, map[int]int{12: 0x08, 13: 0x00})},
		{"ipv6", frame(54, 2, map[int]int{12: 0x86, 13: 0xDD})},
		{"arp", frame(42, 3, map[int]int{12: 0x08, 13: 0x06})},
		{"zero", make([]int, 64)},
	}
	for _, c := range []struct {
		name  string
		progs []string
		rets  map[string]string // "<prog> <frame>" → ret (無いものは ret=0)
	}{
		{"tc_ingress", []string{"count_in"}, nil},
		{"tc_egress_guard", []string{"filter_out"}, map[string]string{"filter_out ipv6": "2"}},
		{"tc_xdp_shared", []string{"on_xdp", "on_tc"}, map[string]string{"on_xdp ipv4": "2", "on_xdp ipv6": "2", "on_xdp arp": "2", "on_xdp zero": "2", "on_xdp -": "2"}},
	} {
		h := buildHarnesses(t, filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", c.name+".rb"))
		var script strings.Builder
		var wantRets []string
		script.WriteString("reset\n")
		for _, p := range c.progs {
			for _, fr := range frames {
				script.WriteString("run " + p + " " + hexOf(fr.f) + "\n")
				wantRets = append(wantRets, c.rets[p+" "+fr.name])
			}
			script.WriteString("run " + p + "\n")
			wantRets = append(wantRets, c.rets[p+" -"])
		}
		script.WriteString("dump\n")
		tw := feed(t, false, script.String(), h.twinBin)
		kn := feed(t, true, script.String(), h.kernelBin)
		if tw != kn {
			t.Errorf("%s: twin and kernel differ\n--- twin\n%s\n--- kernel\n%s", c.name, tw, kn)
			continue
		}
		var rets []string
		for _, l := range strings.Split(tw, "\n") {
			if strings.HasPrefix(l, "ret=") {
				rets = append(rets, strings.TrimPrefix(l, "ret="))
			}
		}
		if strings.Contains(tw, "err=") || len(rets) != len(wantRets) {
			t.Errorf("%s: unexpected output:\n%s", c.name, tw)
			continue
		}
		for i, w := range wantRets {
			if w == "" {
				w = "0"
			}
			if rets[i] != w {
				t.Errorf("%s: run %d: ret=%s, want %s", c.name, i+1, rets[i], w)
			}
		}
		t.Logf("%s: %d lines agree (twin = kernel)\n%s", c.name, strings.Count(tw, "\n"), tw)
	}
}
