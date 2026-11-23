package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E103 の試験 (P025 段 1 — 約 128 KB の event と present の outline)。

// genBig は約 128 KB の event の試験の program (u64 の scalar の member n 個と先頭の seq・末尾の tail — ring の event は配列の member を持てない) を
// dir/t_big.rb に書く (列 ≤ 1023 のために 16 個ごとに改行 — results/E103/gen_big.rb と同じ形)。extra は program の前に置く def。
func genBig(t *testing.T, dir string, n int, extra, call string) string {
	t.Helper()
	wrap := func(items []string, ind string) string {
		var lines []string
		for i := 0; i < len(items); i += 16 {
			j := min(i+16, len(items))
			lines = append(lines, strings.Join(items[i:j], ", "))
		}
		return strings.Join(lines, ",\n"+ind)
	}
	var syms, decls, zeros []string
	for i := 0; i < n; i++ {
		syms = append(syms, fmt.Sprintf(":d%d", i))
		decls = append(decls, fmt.Sprintf("d%d: :u64", i))
		zeros = append(zeros, "0")
	}
	src := fmt.Sprintf(`require "bpf"

Big = Struct.new(:seq,
  %s,
  :tail)
BPF.record(Big, seq: :u64,
  %s,
  tail: :u64)
Bigs = BPF::RingBuf.new("Bigs", Big.new(0,
  %s,
  0), 524288)
In = BPF::ArrayMap.new("In", :u64, 2)
Out = BPF::ArrayMap.new("Out", :u64, 3)
%s
def prog(ctx)
  s = 0
  t = 0
  p = In.lookup(0)
  if p
    s = p.load & 0xFFFFFFFF
  end
  q = In.lookup(1)
  if q
    t = q.load & 0xFFFFFFFF
  end
  if Bigs.output(Big.new(s,
    %s,
    t))
    Out.atomic_add(0, 1)
  else
    Out.atomic_add(1, 1)
  end
%s  BPF::XDP_PASS
end
BPF.xdp :prog
`, wrap(syms, "  "), wrap(decls, "  "), wrap(zeros, "  "), extra, wrap(zeros, "    "), call)
	p := filepath.Join(dir, "t_big.rb")
	os.WriteFile(p, []byte(src), 0o644)
	return p
}


const bigN = 16384

// E103 の H1 (kernel と双子の digest の差動) は走らせられなかった: 16386 の member の Struct の harness (双子・kernel) の Spinel の build は
// gcc -O2 の cc1 が 29 分を超えて終わらない (試験の timeout 30 分 — 止めた)。差動の試験は置かない (Edoc の H1 / H2 — 未達)。

// TestLargeEventOutlined は E103 の H3: 生成した ELF に `__ebpf_present_prog_0` の FUNC が在り、present の見積もりが閾値 (23552) の上。
func TestLargeEventOutlined(t *testing.T) {
	parallel(t) // P018 E075
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := genBig(t, d, bigN, "", "")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	sym, err := exec.Command(filepath.Join(filepath.Dir(cfg.Clang), "llvm-readelf"), "-s", filepath.Join(d, "t_big.bpf.o")).Output()
	if err != nil || !strings.Contains(string(sym), " FUNC ") || !strings.Contains(string(sym), "__ebpf_present_prog_0") {
		t.Errorf("no __ebpf_present_prog_0 FUNC in the ELF (%v):\n%s", err, sym)
	}
	c := exec.Command(cfg.EbpfCompile, "t_big.mlir", "--schema", "t_big.schema.json", "-o", filepath.Join(d, "x.o"), "--report-present-cost="+filepath.Join(d, "cost.tsv"))
	c.Dir = d
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("%v %s", err, o)
	}
	cost, _ := os.ReadFile(filepath.Join(d, "cost.tsv"))
	var est int
	if f := strings.Fields(string(cost)); len(f) >= 3 {
		fmt.Sscan(f[2], &est)
	}
	if est <= 23552 {
		t.Errorf("present estimate %d is not above the 23552 threshold (%q)", est, cost)
	}
	t.Logf("estimate %d; %s", est, strings.TrimSpace(string(cost)))
}
