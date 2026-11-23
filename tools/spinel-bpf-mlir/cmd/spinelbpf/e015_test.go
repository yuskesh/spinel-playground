package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E015 の試験: 双子の XdpMd(bytes) と data 付きの test run (P004 §3・§4)。

// pktrunWant は testdata/pkt/pktrun.rb の出力の期待 (H2・H3 — 3 kernel で同じ)。
const pktrunWant = `len=0 err=SpinelBPF::Other hint=true
len=1 err=SpinelBPF::Other hint=true
len=13 err=SpinelBPF::Other hint=true
len=14 ret=2 out0=7 out1=200
len=15 ret=2 out0=7 out1=200
len=64 ret=2 out0=7 out1=200
len=1500 ret=2 out0=7 out1=200
byte=256 err=SpinelBPF::ValueRange
byte=-1 err=SpinelBPF::ValueRange
`

func buildPktrun(t *testing.T) string {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "e015-")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "pkt", "pktrun.rb"))
	src := filepath.Join(d, "pktrun.rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "pktrun")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestPacketRunHost は E015 の H2・H3 (host、root): data の bytes が届き、0..255 の外は ValueRange、14 byte 未満は kernel が拒否。
func TestPacketRunHost(t *testing.T) {
	parallel(t) // P018 E075
	exe := buildPktrun(t)
	out := feed(t, true, "", exe)
	if out != pktrunWant {
		t.Fatalf("got\n%s\nwant\n%s", out, pktrunWant)
	}
}

// TestPacketRunVM は E015 の H3 (SPINELBPF_VM=1): 同じ実行 file を VM 6.12.111 / 6.6.157 で。
func TestPacketRunVM(t *testing.T) {
	parallel(t) // P018 E075
	if os.Getenv("SPINELBPF_VM") != "1" {
		t.Skip("SPINELBPF_VM=1 runs the VM targets")
	}
	exe := buildPktrun(t)
	dir := filepath.Dir(exe)
	b, _ := os.ReadFile(exe)
	writeExec(t, filepath.Join(dir, "pktrun.kernel"), b)
	os.WriteFile(filepath.Join(dir, "pktrun.script"), nil, 0o644)
	for _, k := range []string{"6.12.111", "6.6.157"} {
		img := filepath.Join(os.Getenv("HOME"), "kernel-build", "linux-"+k, "arch", "x86", "boot", "bzImage")
		o, err := sudoCmd(t, filepath.Join(repoRoot(), "scripts", "run-table-vm.sh"), img, dir).CombinedOutput()
		if err != nil {
			t.Fatalf("vm %s: %v\n%s", k, err, o)
		}
		got, err := os.ReadFile(filepath.Join(dir, "pktrun."+k+".out"))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != pktrunWant {
			t.Errorf("vm %s: got\n%s", k, got)
		}
		t.Logf("vm %s: %s", k, strings.TrimSpace(string(o)))
	}
}

// frame は長さ n の frame (byte i は (i*7+seed) & 0xFF) に fields (offset → byte) を上書きしたもの。
func frame(n, seed int, fields map[int]int) []int {
	f := make([]int, n)
	for i := range f {
		f[i] = (i*7 + seed) & 0xFF
	}
	for off, v := range fields {
		if off < n {
			f[off] = v
		}
	}
	return f
}

func hexOf(f []int) string {
	if len(f) == 0 {
		return "-"
	}
	var b strings.Builder
	for _, v := range f {
		fmt.Fprintf(&b, "%02x", v)
	}
	return b.String()
}

// pktRow は差動の 1 行 (map への poke と frame)。
type pktRow struct {
	pokes []string
	frame []int
}

// pktRows は各正の例の境界の frame (P004 §4 — 各 check(off, N) の off+N と off+N−1・0・1・13・14・大きい frame)。期待の値は持たない。
// s は frame の中身の種 (0 は E015 の行 — E016 は 0・1・2)。
func pktRows(name string, s int) []pktRow {
	var rows []pktRow
	add := func(f []int, pokes ...string) { rows = append(rows, pktRow{pokes, f}) }
	frame := func(n, seed int, fields map[int]int) []int { return frame(n, seed+s*101, fields) }
	ets := []int{0x0800, 0x86DD, 0x0806, 0x8100, 0x0000, 0xFFFF}
	switch name {
	case "pkt_ether": // check(0, 14)
		for _, n := range []int{0, 1, 13, 14, 15, 64, 1500} {
			for i, et := range ets {
				add(frame(n, i*31, map[int]int{12: et >> 8, 13: et & 0xFF}))
			}
		}
	case "pkt_nested": // check(0, 14)・check(14, 20) → 34・check(14 + ihl*4, 4) → 18 + ihl*4
		for _, ihl := range []int{0, 4, 5, 6, 15} {
			for _, proto := range []int{6, 17, 1, 0, 255} {
				l4 := 18 + ihl*4
				for _, n := range []int{13, 14, 33, 34, l4 - 1, l4, 1500} {
					f := frame(n, ihl*13+proto, map[int]int{12: 0x08, 13: 0x00, 14: 0x40 | ihl, 23: proto})
					add(f, "poke Seen 0 "+fmt.Sprint(proto*1000+ihl))
				}
			}
		}
		add(frame(64, 3, map[int]int{12: 0x86, 13: 0xDD, 14: 0x45})) // IPv4 でない
	case "pkt_bounds": // check(0, 1) だけが test run の data の長さで届く (65521 以上の offset の窓は out_of_range)
		for _, n := range []int{0, 1, 13, 14, 64, 1500} {
			add(frame(n, 5, nil))
		}
	case "pkt_off_masked": // check(Off & 0xFFF, 2) — 64 byte の frame で off 62 は中、63 は外
		for _, off := range []int{0, 12, 61, 62, 63, 64, 4095, 4096, 4096 + 62, 0xFFFFFFFF} {
			for _, n := range []int{14, 64} {
				add(frame(n, off&0xFF, nil), fmt.Sprintf("poke Off 0 %d", off))
			}
		}
	}
	return rows
}

// dumpLines は harness の dump の行の数 (全ての map の slot)。
func dumpLines(res *frontend.Result) int {
	n := 0
	for _, m := range res.Maps {
		n += int(m.MaxEntries)
	}
	return n
}

// TestPacketHarnessAgree は E015 の H4 (host、root): 4 つの packet の正の例の境界の frame で、14 byte 以上の行は twin (Spinel)・kernel・CRuby が一致、
// 14 未満の行は twin と CRuby が一致し kernel は `err=SpinelBPF::Other` (H3)。
func TestPacketHarnessAgree(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"pkt_ether", "pkt_nested", "pkt_bounds", "pkt_off_masked"} {
		src := filepath.Join(repoRoot(), "internal", "frontend", "testdata", "pos", name+".rb")
		text, _ := os.ReadFile(src)
		sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
		res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
		if err != nil || res.Diags.Blocking() {
			t.Fatal(err, res.Diags)
		}
		h := buildHarnesses(t, src)
		rows := pktRows(name, 0)
		var script strings.Builder
		for _, r := range rows {
			script.WriteString("reset\n")
			for _, p := range r.pokes {
				script.WriteString(p + "\n")
			}
			fmt.Fprintf(&script, "run %s %s\ndump\n", res.Programs[0].Name, hexOf(r.frame))
		}
		tw := strings.Split(feed(t, false, script.String(), h.twinBin), "\n")
		kn := strings.Split(feed(t, true, script.String(), h.kernelBin), "\n")
		rb := strings.Split(crubyFeed(t, script.String(), h), "\n")
		if o := os.Getenv("E015_OUT"); o != "" { // 成果物 (Edoc の results)
			os.WriteFile(filepath.Join(o, name+".script"), []byte(script.String()), 0o644)
			os.WriteFile(filepath.Join(o, name+".twin.out"), []byte(strings.Join(tw, "\n")), 0o644)
			os.WriteFile(filepath.Join(o, name+".kernel.out"), []byte(strings.Join(kn, "\n")), 0o644)
			os.WriteFile(filepath.Join(o, name+".cruby.out"), []byte(strings.Join(rb, "\n")), 0o644)
		}
		dl := dumpLines(res)
		at := 0
		both, short, bad := 0, 0, 0
		for i, r := range rows {
			n := 1 + len(r.pokes) + 1 + dl
			if at+n > len(tw) || at+n > len(kn) || at+n > len(rb) {
				t.Fatalf("%s: output too short at row %d", name, i)
			}
			tr, kr, cr := strings.Join(tw[at:at+n], "\n"), strings.Join(kn[at:at+n], "\n"), strings.Join(rb[at:at+n], "\n")
			if tr != cr {
				bad++
				t.Errorf("%s row %d (len %d): twin and CRuby differ\n--- twin\n%s\n--- cruby\n%s", name, i, len(r.frame), tr, cr)
			}
			if len(r.frame) >= 14 {
				both++
				if tr != kr {
					bad++
					t.Errorf("%s row %d (len %d): twin and kernel differ\n--- twin\n%s\n--- kernel\n%s", name, i, len(r.frame), tr, kr)
				}
			} else {
				short++
				if kn[at+1+len(r.pokes)] != "err=SpinelBPF::Other" {
					bad++
					t.Errorf("%s row %d (len %d): the kernel accepted a short test-run data: %s", name, i, len(r.frame), kn[at+1+len(r.pokes)])
				}
			}
			at += n
		}
		t.Logf("%s: %d rows — %d with twin = kernel = CRuby, %d short rows twin = CRuby only, %d mismatches", name, len(rows), both, short, bad)
	}
}
