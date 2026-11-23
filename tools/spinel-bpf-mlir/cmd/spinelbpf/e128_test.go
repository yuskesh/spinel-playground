package main

import (
	"encoding/binary"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// E128 の試験: netfilter (P026 段 ②)。

func nfData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "nf", name)
}

// e128Out は E128_OUT が在ればその下の file に s を書く (観測を results に — E126 の完了のレビューの注)。
func e128Out(t *testing.T, name, s string) {
	if o := os.Getenv("E128_OUT"); o != "" {
		if err := os.WriteFile(filepath.Join(o, name), []byte(s), 0o644); err != nil {
			t.Errorf("writing %s: %v", name, err)
		}
	}
}

// TestNfBuildNoRoot は E128 の root なしの部分: nfio と nfattach (C の helper の netns と UDP を持つ) が build と link を通る。
func TestNfBuildNoRoot(t *testing.T) {
	parallel(t)
	cfg := lpmConfig(t)
	for _, n := range []string{"nfio", "nfattach"} {
		buildDataProgram(t, nfData(n+".rb"), cfg)
	}
}

// TestNfUserAPI は E128 H4 (root、成功する attach はしない): load の unmet 0、attach_netfilter と test_run_netfilter の誤りの class と判定 (手で書いた期待 nfio.want)。
func TestNfUserAPI(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, nfData("nfio.rb"), lpmConfig(t))
	want, _ := os.ReadFile(nfData("nfio.want"))
	out := feed(t, true, "", exe)
	t.Logf("nfio:\n%s", out)
	if out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

var nfNetnsLine = regexp.MustCompile(`^netns before=[0-9]+ after=[0-9]+ moved=1\n`)

// nfAttach は nfattach を root で走らせ、1 行目 (netns の inode の前と後 — 違うときだけ attach、E128 追補 1) を確かめて残りを返す。
func nfAttach(t *testing.T, exe string) (netns, rest string) {
	t.Helper()
	out := feed(t, true, "", exe)
	loc := nfNetnsLine.FindStringIndex(out)
	if loc == nil {
		t.Fatalf("the first line is not a moved netns:\n%s", out)
	}
	return out[:loc[1]], out[loc[1]:]
}

// TestNfAttach は E128 H6 (root、自分の netns だけ): 自分の netns の lo の LOCAL_OUT で payload 1〜36 だけが送れ 37〜200 は EPERM、受け手は 1〜36
// (手で書いた期待 nfattach.want — netns の行は inode が run ごとに変わるので moved=1 だけを見る)。観測は E128_OUT の nfattach.out に。
func TestNfAttach(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, nfData("nfattach.rb"), lpmConfig(t))
	netns, rest := nfAttach(t, exe)
	t.Logf("nfattach:\n%s%s", netns, rest)
	e128Out(t, "nfattach.out", netns+rest)
	want, _ := os.ReadFile(nfData("nfattach.want"))
	if rest != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", rest, want)
	}
}

// nfIP は n byte の IPv4 / UDP の packet (eth の header は無い — bpf-mlir の trcheck の ip: と同じ形)、nfFrame は eth の header の付いた n byte の frame
// (trcheck の frame: と同じ)。
func nfIP(n int) []byte {
	return nfFrameBytes(n + 14)[14:]
}

func nfFrameBytes(n int) []byte {
	b := make([]byte, n)
	copy(b[0:6], []byte{0x02, 0, 0, 0, 0, 2})
	copy(b[6:12], []byte{0x02, 0, 0, 0, 0, 1})
	b[12], b[13] = 0x08, 0x00
	b[14] = 0x45
	binary.BigEndian.PutUint16(b[16:18], uint16(n-14))
	b[22], b[23] = 64, 17
	copy(b[26:34], []byte{10, 0, 0, 1, 10, 0, 0, 2})
	return b
}

// tNfScript は t_nf の表 (期待の値を持たない — 双子と kernel を比べる): LOCAL_OUT (3) は IP の長さ、PRE_ROUTING (0)・LOCAL_IN (1) は frame の長さ、
// pf 10 は LOCAL_OUT だけ (bpf-mlir E402 の case と同じ — E128 追補 2)、固定の seed の乱数 64。`run <prog> <hex> <hook> <pf>`。
func tNfScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	run := func(data []byte, hook, pf int) { fmt.Fprintf(&b, "run small_only %x %d %d\ndump\n", data, hook, pf) }
	row("n_out") // LOCAL_OUT の IP: len 20・64 (accept の最後)・65 (drop の最初)・1500、pf 10
	for _, n := range []int{20, 64, 65, 1500} {
		run(nfIP(n), 3, 2)
	}
	run(nfIP(40), 3, 10)
	row("n_in") // PRE_ROUTING・LOCAL_IN の frame: len 20 (34 byte)・64 (78)・65 (79)
	for _, h := range []int{0, 1} {
		for _, n := range []int{34, 78, 79} {
			run(nfFrameBytes(n), h, 2)
		}
	}
	row("n_random")
	r := rand.New(rand.NewSource(128))
	hooks := []int{0, 1, 3}
	for i := 0; i < 64; i++ {
		h := hooks[r.Intn(3)]
		if h == 3 {
			run(nfIP(20+r.Intn(1481)), 3, 2)
		} else {
			run(nfFrameBytes(34+r.Intn(1481)), h, 2)
		}
	}
	return b.String()
}

// TestNfTable は E128 H5 (host 7.1.8、root、test run だけ): t_nf の表で双子と kernel の出力が行ごとに一致、kernel の出力に accept の ret=1 と drop の ret=0・
// hook と pf の値が意図した行に在る。
func TestNfTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, nfData("t_nf.rb"))
	script := tNfScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## n_out\n", "ret=1\n", "Out[0]=3\n", "Out[1]=2\n", "Out[2]=64\n", "ret=0\n", "Out[2]=65\n", "Out[1]=10\n", "## n_in\n", "Out[0]=0\n", "Out[2]=20\n", "Out[0]=1\n", "## n_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestNfTableOut は E128 の成果物: 表の手順と kernel・双子の出力を E128_OUT に残す。
func TestNfTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E128_OUT")
	if o == "" {
		t.Skip("E128_OUT")
	}
	h := buildHarnesses(t, nfData("t_nf.rb"))
	script := tNfScript()
	os.WriteFile(filepath.Join(o, "t_nf.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_nf.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_nf.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
