package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E124 の試験 (P026 — † XDP の redirect_map と devmap)。H0 は bml の口の確かめ (devmap の load・ifindex の put / get・存在しない ifindex の拒否)。

// TestDevmapBmlPut は H0 (root): devmap を持つ ELF の load は OK、lo (ifindex 1) の put は OK で get は 1、存在しない ifindex 999999 の put は
// bml の誤り (kernel が devmap の更新を拒む)。通らなければ E124 は止めて報告 (P026 §1 — bml の計画はしない)。
func TestDevmapBmlPut(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "devmap_put")
	for _, w := range []string{"load kind=OK", "put lo kind=OK", "get=1"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "put 999999 kind=SpinelBPF::") || strings.Contains(out, "put 999999 kind=OK") {
		t.Errorf("a put of a nonexistent ifindex must fail loudly")
	}
}

// redirFrame は先頭 byte が b の 14 byte の frame (残りは 0) の hex。
func redirFrame(b int) string {
	return fmt.Sprintf("%02x", b) + strings.Repeat("00", 13)
}

// redirScript は H3 / H4 の入力: Ports[0] と Ports[2] に lo (ifindex 1)、先頭 byte 0・1・2・3 の frame を run。
func redirScript() string {
	var s strings.Builder
	s.WriteString("reset\npoke Ports 0 1\npoke Ports 2 1\n")
	for b := 0; b < 4; b++ {
		s.WriteString("run redir " + redirFrame(b) + "\n")
	}
	return s.String()
}

// redirRets は出力の `ret=` の列。
func redirRets(out string) []string {
	var r []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); strings.HasPrefix(l, "ret=") {
			r = append(r, l)
		}
	}
	return r
}

func redirSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "xdp_redirect.rb")
}

// TestRedirectArtefacts は H1: .mlir の redirect_map の終端、schema の devmap、ELF の requirements の map と helper の行。
func TestRedirectArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(redirSrc())
	src := filepath.Join(d, "xdp_redirect.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "xdp_redirect.mlir"))
	if !strings.Contains(string(m), `ebpf.redirect_map %m0[`) || !strings.Contains(string(m), `: !ebpf.map<"devmap", i32, i32>, i32 fallback "pass"`) {
		t.Errorf(".mlir lacks the redirect_map terminator:\n%s", m)
	}
	s, _ := os.ReadFile(filepath.Join(d, "xdp_redirect.schema.json"))
	if !strings.Contains(strings.Join(strings.Fields(string(s)), ""), `"symbol":"Ports","kind":"devmap"`) {
		t.Errorf("schema: want Ports as a devmap:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "xdp_redirect.bpf.o"))
	for _, w := range []string{"ebpf-requirements 5\n", "helper\tredir\tredirect_map\t51\n", "map\tPorts\tdevmap\t14\tu32\tu32\t4\t0\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestRedirectTwinSmoke は H3: 双子の戻り値 4・2・4・2 (key 0 / 2 は entry 在り — XDP_REDIRECT、1 / 3 は fallback の XDP_PASS)。
func TestRedirectTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "xdp_redirect")
	got := redirRets(feed(t, false, redirScript(), tw))
	if strings.Join(got, " ") != "ret=4 ret=2 ret=4 ret=2" {
		t.Errorf("twin: want ret=4 ret=2 ret=4 ret=2, got %v", got)
	}
}

// TestRedirectDifferential は H4 (root): kernel の test run の戻り値が 4・2・4・2 で双子と一致。
func TestRedirectDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, redirSrc())
	k := feed(t, true, redirScript(), h.kernelBin)
	w := feed(t, false, redirScript(), h.twinBin)
	t.Log(k)
	kr, wr := redirRets(k), redirRets(w)
	if strings.Join(kr, " ") != "ret=4 ret=2 ret=4 ret=2" || strings.Join(kr, " ") != strings.Join(wr, " ") {
		t.Errorf("kernel %v, twin %v — want ret=4 ret=2 ret=4 ret=2 on both", kr, wr)
	}
}
