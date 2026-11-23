package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E129 の試験 (P026 — † sk_lookup と sk.assign)。H0 は bml の口の確かめ (sockmap の load・socket の fd の put・socket でない fd の拒否)。

// TestSockmapBmlPut は H0 (root): sockmap を持つ sk_lookup の ELF の load は OK、自分の UDP の socket の fd の put は OK、pipe の fd の put は
// bml の誤り (kernel が sockmap の更新を拒む)。通らなければ E129 は止めて報告 (P026 §1)。
func TestSockmapBmlPut(t *testing.T) {
	requireUnverified(t)
	out := rawtpFixture(t, "sockmap_put")
	for _, w := range []string{"load kind=OK", "put udp kind=OK"} {
		if !strings.Contains(out, w+"\n") {
			t.Errorf("want %q", w)
		}
	}
	if !strings.Contains(out, "put pipe kind=SpinelBPF::") || strings.Contains(out, "put pipe kind=OK") {
		t.Errorf("a put of a non-socket fd must fail loudly")
	}
}

// skScript は H3 / H4 の入力: Socks[0] に 127.0.0.1:7301 の UDP の socket、port 7300 (k 0) / 7301 (k 1) の UDP と 7300 の TCP を run し、
// run ごとに dump。
func skScript() string {
	return "reset\nsput Socks 0 udp 7301\nrun pick proto=17 port=7300\ndump\nrun pick proto=17 port=7301\ndump\nrun pick proto=6 port=7300\ndump\n"
}

// skWant は H3 / H4 の run ごとの Out (k 0 の UDP は選ぶ 0、k 1 は entry 無し −2、TCP は protocol 違い −91 — run の数 1・2・3) と戻り値 (SK_PASS)。
const skWant = "Out[0]=0 Out[1]=1 Out[0]=-2 Out[1]=2 Out[0]=-91 Out[1]=3"
const skWantRet = "ret=1 ret=1 ret=1"

// skLines は出力の prefix の行の列。
func skLines(out string, prefix ...string) []string {
	var r []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		for _, p := range prefix {
			if strings.HasPrefix(l, p) {
				r = append(r, l)
			}
		}
	}
	return r
}

func skSrc() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", "sk_lookup_assign.rb")
}

// TestSkLookupArtefacts は H1: .mlir の sock.map_lookup → ref_check (present: sk.assign → release、absent: −2)、schema の sockmap、
// ELF の requirements の program・helper・map の行。
func TestSkLookupArtefacts(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(skSrc())
	src := filepath.Join(d, "sk_lookup_assign.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	m, _ := os.ReadFile(filepath.Join(d, "sk_lookup_assign.mlir"))
	for _, w := range []string{`ebpf.program @pick "sk_lookup"`, `ebpf.ctx.field %ctx "local_port"`, `ebpf.sock.map_lookup %m0[`, `ebpf.sock.ref_check `, `-> i64 present {`, `= ebpf.sk.assign %ctx, `, `ebpf.sock.release `, `= arith.constant -2 : i64`} {
		if !strings.Contains(string(m), w) {
			t.Errorf(".mlir lacks %q:\n%s", w, m)
		}
	}
	s, _ := os.ReadFile(filepath.Join(d, "sk_lookup_assign.schema.json"))
	if !strings.Contains(strings.Join(strings.Fields(string(s)), ""), `"symbol":"Socks","kind":"sockmap"`) {
		t.Errorf("schema: want Socks as a sockmap:\n%s", s)
	}
	r := elfRequirements(t, cfg, filepath.Join(d, "sk_lookup_assign.bpf.o"))
	t.Log(r)
	for _, w := range []string{"ebpf-requirements 9\n", "program\tpick\tsk_lookup\t30\n", "helper\tpick\tsk_assign\t124\n", "helper\tpick\tsk_release\t86\n", "helper\tpick\tmap_lookup_elem\t1\n", "map\tSocks\tsockmap\t15\tu32\tu64\t2\t0\n"} {
		if !strings.Contains(string(r), w) {
			t.Errorf("requirements lack %q:\n%s", w, r)
		}
	}
}

// TestSkLookupTwinSmoke は H3: 双子の戻り値は 3 つとも SK_PASS (1)、run ごとの Out[0] は 0・−2・−91、Out[1] は 1・2・3。
func TestSkLookupTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	tw, _ := twinOnly(t, "sk_lookup_assign")
	out := feed(t, false, skScript(), tw)
	got, ret := skLines(out, "Out["), skLines(out, "ret=")
	t.Log(got, ret)
	if strings.Join(got, " ") != skWant || strings.Join(ret, " ") != skWantRet {
		t.Errorf("twin: want %s / %s, got %v / %v", skWant, skWantRet, got, ret)
	}
}

// TestSkLookupDifferential は H4 (root): kernel の test run の戻り値と run ごとの Out が双子と同じ (0・−2・−91 と 1・2・3)、ctx_out の cookie は
// 1 つ目だけ sput の socket の cookie (SO_COOKIE) と同じで 2・3 つ目は 0 (選んでいない)。
func TestSkLookupDifferential(t *testing.T) {
	requireUnverified(t)
	h := buildHarnesses(t, skSrc())
	k := feed(t, true, skScript(), h.kernelBin)
	w := feed(t, false, skScript(), h.twinBin)
	t.Log(k)
	kg, wg := skLines(k, "Out["), skLines(w, "Out[")
	kr, wr := skLines(k, "ret="), skLines(w, "ret=")
	if strings.Join(kg, " ") != skWant || strings.Join(kg, " ") != strings.Join(wg, " ") {
		t.Errorf("Out: kernel %v, twin %v — want %s on both", kg, wg, skWant)
	}
	if strings.Join(kr, " ") != skWantRet || strings.Join(kr, " ") != strings.Join(wr, " ") {
		t.Errorf("ret: kernel %v, twin %v — want %s on both", kr, wr, skWantRet)
	}
	sc, ck := skLines(k, "scookie="), skLines(k, "cookie=")
	if len(sc) != 1 || len(ck) != 3 || sc[0] == "scookie=0" || sc[0] == "scookie=-1" || ck[0] != sc[0][1:] || ck[1] != "cookie=0" || ck[2] != "cookie=0" {
		t.Errorf("cookie: want the sput cookie on the first run and 0 on the others, got %v / %v", sc, ck)
	}
}
