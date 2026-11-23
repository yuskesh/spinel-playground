package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E079 の試験: 例 tccount (P019 §4) — XDP と tcx の ingress / egress の 3 つが 1 つの map を数える。

var tccountArtefacts = []string{"tccount.mlir", "tccount.schema.json", "tccount.maps.json", "tccount.domain.json", "tccount.bpf.o",
	"tccount.compile_warnings.txt", "tccount_embed.S", "tccount_embed.o"}

const tccountSelftest = `count xdp udp=1 echo_request=1 echo_reply=1 unreachable=1 other=1
count tc_ingress udp=1 echo_request=1 echo_reply=1 unreachable=1 other=1
count tc_egress udp=1 echo_request=1 echo_reply=1 unreachable=1 other=1
selftest ok
`

func linkedTccount(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e079-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "tccount", "tccount.rb"))
	src := filepath.Join(d, "tccount.rb")
	os.WriteFile(src, b, 0o644)
	r, err := Build(cfg, src)
	if err != nil {
		t.Fatal(err)
	}
	for _, x := range r.Output.Result.Diags {
		t.Errorf("unexpected diagnostic: %s", x)
	}
	exe := filepath.Join(d, "tccount")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestTccountArtefacts は E079 の H1: 2 回の build の生成物が commit 済みの物と byte 同じ、ELF の section は xdp・tcx/ingress・tcx/egress。
func TestTccountArtefacts(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "tccount", "tccount.rb"))
	for i := 0; i < 2; i++ {
		d := t.TempDir()
		src := filepath.Join(d, "tccount.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		for _, f := range tccountArtefacts {
			got, _ := os.ReadFile(filepath.Join(d, f))
			want, err := os.ReadFile(filepath.Join(repoRoot(), "examples", "tccount", f))
			if err != nil || !bytes.Equal(got, want) {
				t.Errorf("build %d: %s differs from the committed one (%v)", i, f, err)
			}
		}
	}
	elf, _ := os.ReadFile(filepath.Join(repoRoot(), "examples", "tccount", "tccount.bpf.o"))
	for _, s := range []string{"xdp\x00", "tcx/ingress\x00", "tcx/egress\x00"} {
		if !bytes.Contains(elf, []byte(s)) {
			t.Errorf("the ELF has no section name %q", strings.TrimSuffix(s, "\x00"))
		}
	}
}

// TestTccountSelftestHost は E079 の H2 (host、root) と H4 (uid 1000 の CAP_BPF + CAP_NET_ADMIN): 5 種の frame × 3 つの program の test run で 15 slot が全て 1、
// 判定は XDP が XDP_PASS・tc が TC_PASS。非 root も同じ出力。
func TestTccountSelftestHost(t *testing.T) {
	parallel(t) // P018 E075
	exe := linkedTccount(t)
	out := feed(t, true, "", exe, "--selftest")
	if !strings.HasSuffix(out, tccountSelftest) || !strings.Contains(out, "unmet (not blocking): 0 ") {
		t.Fatalf("root selftest:\n%s", out)
	}
	nr, err := nonroot(t, "+bpf,+net_admin", "", exe, "--selftest")
	if err != nil || nr != out {
		t.Errorf("non-root +bpf,+net_admin: want the root output, got err %v\n%s", err, nr)
	}
	t.Log(out)
}

// TestTccountVeth は E079 の H3 (host、root): veth の peer に 3 つを attach し、host から UDP 20 (閉じた port) と ping 5 — ingress (XDP と tcx) は UDP 20・
// echo request 5、egress (tcx) は unreachable 20・echo reply 5、他は 0、tcx の向きが宣言のとおり、終了の後に program が残らない。
func TestTccountVeth(t *testing.T) {
	parallel(t) // P018 E075・E084: hostnet (pid の netns・interface・subnet) を通る — 類 d の外
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	out, err := sudo(t, "BIN="+linkedTccount(t), "N=20", "M=5", filepath.Join(repoRoot(), "scripts", "run-tccount-host.sh"))
	if err != nil || !strings.Contains(out, "RESULT ok") {
		t.Fatalf("err=%v\n%s", err, out)
	}
	t.Log(out)
}
