package main

import (
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E130 の試験: flow_dissector (P026 段 ② — F50)。

func flowData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "flow", name)
}

// TestFlowBuildNoRoot は E130 の root なしの部分: flowio (C の helper の netns を持つ) が build と link を通る。
func TestFlowBuildNoRoot(t *testing.T) {
	parallel(t)
	buildDataProgram(t, flowData("flowio.rb"), lpmConfig(t))
}

// TestFlowUserAPI は E130 H4 (root、自分の netns だけ): load の unmet 0、誤りの class、自分の netns への attach_netns と detach (手で書いた期待 flowio.want —
// 1 行目の netns の inode の行は moved=1 だけを見る)。観測は E130_OUT の flowio.out に。
func TestFlowUserAPI(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildDataProgram(t, flowData("flowio.rb"), lpmConfig(t))
	out := feed(t, true, "", exe)
	t.Logf("flowio:\n%s", out)
	if o := os.Getenv("E130_OUT"); o != "" {
		os.WriteFile(filepath.Join(o, "flowio.out"), []byte(out), 0o644)
	}
	loc := nfNetnsLine.FindStringIndex(out)
	if loc == nil {
		t.Fatalf("the first line is not a moved netns:\n%s", out)
	}
	want, _ := os.ReadFile(flowData("flowio.want"))
	if rest := out[loc[1]:]; rest != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", rest, want)
	}
}

// flowFrames は差動の表の frame (bpf-mlir E443 の trcases と同じ形の IPv4 の UDP / TCP / ICMP と、IPv6 の UDP、IPv6 の ethertype の 33 byte)。
func flowFrames() []string {
	v4 := "0200000000020200000000010800"
	return []string{
		v4 + "4500002e00000000401100000a0000010a00000212340035001a0000000000000000000000000000000000000000",
		v4 + "4600003200000000400600000a0000010a000002010101010050c350000000000000000050000000000000000000",
		v4 + "4500002e00000000400100000a0000010a0000020800000000000000000000000000000000000000000000000000",
		"02000000000202000000000186dd" + "6000000000081140" + "20010db8000000000000000000000001" + "20010db8000000000000000000000002" + "123400350008" + "0000",
		v4 + "4500002e000000004011",
	}
}

// tFlowScript は t_flow の表 (期待の値を持たない — 双子と kernel を比べる): 3 つの program × 固定の frame、frame の長さ 14・34・64・1514 の 0 の frame、
// 固定の seed の乱数 32 (長さ 14〜1514 の乱数の byte)。
func tFlowScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\n", label) }
	run := func(h string) {
		for _, p := range []string{"flow4", "flow6", "clamp"} {
			fmt.Fprintf(&b, "run %s %s\n", p, h)
		}
	}
	row("f_frames")
	for _, h := range flowFrames() {
		run(h)
	}
	row("f_lens")
	for _, n := range []int{14, 34, 64, 1514} {
		run(strings.Repeat("00", n))
	}
	row("f_random")
	r := rand.New(rand.NewSource(130))
	for i := 0; i < 32; i++ {
		d := make([]byte, 14+r.Intn(1501))
		r.Read(d)
		if i%2 == 0 {
			d[12], d[13] = 0x08, 0x00
		}
		run(hex.EncodeToString(d))
	}
	return b.String()
}

// TestFlowTable は E130 H5 (host 7.1.8、root、test run だけ): t_flow の表で双子と kernel の出力 (判定と key の全て) が行ごとに一致、kernel の出力に
// IPv4 の UDP の key・clamp の値・drop が意図した行に在る。
func TestFlowTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, flowData("t_flow.rb"))
	script := tFlowScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## f_frames\n", "ret=0 keys=14,34,2048,0,0,0,17,8,", "ret=129 keys=14,", "## f_lens\n", "ret=2 keys=14,14,0,", "## f_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestFlowTableOut は E130 の成果物: 表の手順と kernel・双子の出力を E130_OUT に残す。
func TestFlowTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E130_OUT")
	if o == "" {
		t.Skip("E130_OUT")
	}
	h := buildHarnesses(t, flowData("t_flow.rb"))
	script := tFlowScript()
	os.WriteFile(filepath.Join(o, "t_flow.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_flow.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_flow.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}
