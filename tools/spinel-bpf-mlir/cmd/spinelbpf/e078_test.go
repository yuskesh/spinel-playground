package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// E078 の試験 (P019): sched_cls の差動 — t_tc (t_pkt の読みを XDP の t_x と sched_cls の t_c に同じ形で) の表で双子 = kernel、tc の test run の
// 長さの表、kernel の OutX = OutT (同じ読み)、変異の対照。

func tTcSrc() string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tc", "t_tc.rb")
}

// tcRow は表の 1 行 (frame・ethertype・Seen の値)。
type tcRow struct {
	f    []int
	et   int
	seen int
}

// tcRows は長さ × ethertype × byte 1 × 種の表 (期待の値を持たない — 双子が model)。
func tcRows() []tcRow {
	var rows []tcRow
	for s := 0; s < 2; s++ {
		for _, n := range []int{0, 1, 13, 14, 15, 17, 18, 19, 20, 33, 34, 35, 45, 46, 53, 54, 55, 60, 77, 80, 81, 100, 1500} {
			for _, et := range []int{0x0000, 0x0800, 0x86DD, 0x0806} {
				for _, b1 := range []int{0, 40, 255} {
					rows = append(rows, tcRow{frame(n, b1*3+s*101, map[int]int{1: b1, 12: et >> 8, 13: et & 0xFF}), et, s*37 + n})
				}
			}
		}
	}
	return rows
}

// tcAccept は H2 の長さの表: kernel の sched_cls の test run が受ける行 (14 以上、IPv4 は 34 以上、IPv6 は 54 以上)。
func tcAccept(n, et int) bool {
	return n >= 14 && !(et == 0x0800 && n < 34) && !(et == 0x86DD && n < 54)
}

func tcScript(rows []tcRow) string {
	var b strings.Builder
	for _, r := range rows {
		h := hexOf(r.f)
		b.WriteString("reset\npoke Seen 0 " + itoa(r.seen) + "\nrun t_x " + h + "\nrun t_c " + h + "\ndump\n")
	}
	return b.String()
}

// tcResult は表の比べの結果。
type tcResult struct {
	rows, xdpBoth, tcBoth, same int
	bad, table, differ          []string       // 双子と kernel の不一致・長さの表の外れ・OutX と OutT の違い
	slots                       map[string]int // 不一致の行の slot (ret は "t_x ret" / "t_c ret")
}

// compareTc は双子と kernel の出力を行ごとに比べる (1 行 = reset・poke・run 2 つ・dump の 1 + 1 + 2 + dl 行)。
func compareTc(rows []tcRow, dl int, twin, kernel string) tcResult {
	tw, kn := strings.Split(twin, "\n"), strings.Split(kernel, "\n")
	r := tcResult{rows: len(rows), slots: map[string]int{}}
	at := 0
	for i, row := range rows {
		n := 4 + dl
		if at+n > len(tw) || at+n > len(kn) {
			r.bad = append(r.bad, "output too short at row "+itoa(i))
			return r
		}
		where := "row " + itoa(i) + " (len " + itoa(len(row.f)) + " et " + itoa(row.et) + ")"
		xOK, cOK := strings.HasPrefix(kn[at+2], "ret="), strings.HasPrefix(kn[at+3], "ret=")
		if xOK != (len(row.f) >= 14) || (!xOK && kn[at+2] != "err=SpinelBPF::Other") {
			r.table = append(r.table, where+" xdp: "+kn[at+2])
		}
		if cOK != tcAccept(len(row.f), row.et) || (!cOK && kn[at+3] != "err=SpinelBPF::Other") {
			r.table = append(r.table, where+" tc: "+kn[at+3])
		}
		diff := func(j int, slot string) {
			if tw[j] != kn[j] {
				r.bad = append(r.bad, where+" twin/kernel: "+tw[j]+" | "+kn[j])
				r.slots[slot]++
			}
		}
		diff(at, "reset")
		diff(at+1, "poke")
		if xOK {
			r.xdpBoth++
			diff(at+2, "t_x ret")
		}
		if cOK {
			r.tcBoth++
			diff(at+3, "t_c ret")
		}
		outX, outT := map[string]string{}, map[string]string{}
		for j := at + 4; j < at+n; j++ {
			slot := kn[j]
			if k := strings.Index(slot, "]="); k > 0 {
				slot = slot[:k+1]
			}
			switch {
			case strings.HasPrefix(kn[j], "OutX["):
				outX[strings.TrimPrefix(kn[j], "OutX")] = ""
				if xOK {
					diff(j, slot)
				}
			case strings.HasPrefix(kn[j], "OutT["):
				outT[strings.TrimPrefix(kn[j], "OutT")] = ""
				if cOK {
					diff(j, slot)
				}
			default:
				diff(j, slot)
			}
		}
		if xOK && cOK { // H3: kernel の OutX[k] と OutT[k] (同じ行の添字と値の組の集合)
			r.same++
			for k := range outX {
				if _, ok := outT[k]; !ok {
					r.differ = append(r.differ, where+" OutX"+k+" has no equal OutT slot")
				}
			}
		}
		at += n
	}
	return r
}

// tcTable は harness の組で表を走らせて比べる。
func tcTable(t *testing.T, rows []tcRow, h harnessSet) tcResult {
	t.Helper()
	script := tcScript(rows)
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if o := os.Getenv("E078_OUT"); o != "" {
		os.WriteFile(filepath.Join(o, "t_tc.script"), []byte(script), 0o644)
		os.WriteFile(filepath.Join(o, "t_tc.twin.out"), []byte(tw), 0o644)
		os.WriteFile(filepath.Join(o, "t_tc.kernel.out"), []byte(kn), 0o644)
	}
	return compareTc(rows, 18+18+1, tw, kn)
}

// TestTcTable は E078 の H1〜H3 (host、root): 552 行で双子 = kernel、kernel の受け / 拒否が長さの表のとおり、両方を受けた行で OutX = OutT。
func TestTcTable(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	rows := tcRows()
	r := tcTable(t, rows, buildHarnesses(t, tTcSrc()))
	t.Logf("%d rows: xdp accepted %d, tc accepted %d, both %d; mismatches %d, table %d, OutX≠OutT %d", r.rows, r.xdpBoth, r.tcBoth, r.same, len(r.bad), len(r.table), len(r.differ))
	for _, b := range first(r.bad, 5) {
		t.Error("H1: " + b)
	}
	for _, b := range first(r.table, 5) {
		t.Error("H2: " + b)
	}
	for _, b := range first(r.differ, 5) {
		t.Error("H3: " + b)
	}
	if r.rows != 552 || r.same == 0 || r.tcBoth == r.xdpBoth {
		t.Errorf("unexpected table shape: %+v", r)
	}
}

// inTc は t_c の program の本文 (`ebpf.program @t_c` の後) だけに f を当てる。
func inTc(f func(string) (string, bool)) func(string) (string, bool) {
	return func(s string) (string, bool) {
		i := strings.Index(s, "ebpf.program @t_c ")
		if i < 0 {
			return s, false
		}
		tail, ok := f(s[i:])
		return s[:i] + tail, ok
	}
}

// TestTcMutations は E078 の H4 (a)(b) (host、root): 変異の .mlir で kernel の harness を作り直し、表の不一致が意図した slot だけに出る。
func TestTcMutations(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	src := tTcSrc()
	rows := tcRows()
	for _, m := range []struct {
		name    string
		rewrite func(string) (string, bool)
		slots   []string // 不一致が出てよい slot (全て出る — 他の slot は出ない)
		lens    []int    // 不一致が出てよい長さ (nil は全て)
	}{
		{"(a) the guard's verdicts swapped", inTc(func(s string) (string, bool) {
			return strings.Replace(s, `"drop" else "pass"`, `"pass" else "drop"`, 1), strings.Count(s, `"drop" else "pass"`) == 1
		}), []string{"t_c ret"}, nil},
		{"(b) t_c's check(14, 20) -> len 19", inTc(func(s string) (string, bool) {
			return strings.ReplaceAll(strings.Replace(s, "] len 20 :", "] len 19 :", 1), "!ebpf.pkt_window<20>", "!ebpf.pkt_window<19>"), strings.Count(s, "] len 20 :") == 1
		}), []string{"OutT[14]", "OutT[15]", "OutT[16]"}, []int{33}},
	} {
		h, cerr := mutatedPkt(t, src, m.rewrite)
		if cerr != nil {
			t.Errorf("%s: ebpf-compile refused: %v", m.name, cerr)
			continue
		}
		r := tcTable(t, rows, h)
		t.Logf("%s: %d mismatching lines, slots %v", m.name, len(r.bad), r.slots)
		allowed := map[string]bool{}
		for _, s := range m.slots {
			allowed[s] = true
			if r.slots[s] == 0 {
				t.Errorf("%s: want mismatches in %s, got %v", m.name, s, r.slots)
			}
		}
		for s := range r.slots {
			if !allowed[s] {
				t.Errorf("%s: a mismatch outside the intended slots: %s (%v)", m.name, s, r.slots)
			}
		}
		if m.lens != nil {
			for _, b := range r.bad {
				okLen := false
				for _, n := range m.lens {
					okLen = okLen || strings.Contains(b, "(len "+itoa(n)+" ")
				}
				if !okLen {
					t.Errorf("%s: a mismatch at an unintended length: %s", m.name, b)
					break
				}
			}
		}
		t.Logf("%s: table %d, OutX≠OutT %d (the kernel's OutT differs from OutX only where the mutation changes the read)", m.name, len(r.table), len(r.differ))
	}
}

// TestTcDirectionMutation は E078 の H4 (c)(c') (host、root): attach_kind (E077) の tc_in の向きを egress に書き換える — .mlir と schema の両方なら
// build が通り attach の向きが宣言 (ingress) と違う (E077 の試験の dir の行が落ちる)、.mlir だけなら ebpf-compile が schema との食い違いで止める。
// host の lo に pass だけの program を短く attach する — 独占 (P018 の類 d)。
func TestTcDirectionMutation(t *testing.T) {
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	cfg, _ := defaultConfig()
	mlirSwap := func(s string) string {
		return strings.Replace(s, `ebpf.program @tc_in "sched_cls" attach "ingress"`, `ebpf.program @tc_in "sched_cls" attach "egress"`, 1)
	}
	schemaSwap := func(s string) string {
		return strings.Replace(s, "\"name\": \"tc_in\",\n        \"kind\": \"sched_cls\",\n        \"attach_target\": \"ingress\"", "\"name\": \"tc_in\",\n        \"kind\": \"sched_cls\",\n        \"attach_target\": \"egress\"", 1)
	}
	for _, c := range []struct {
		name   string
		schema bool
	}{{"control", false}, {"(c) .mlir and schema", true}, {"(c') .mlir only", false}} {
		d := t.TempDir()
		b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "tc", "attach_kind.rb"))
		src := filepath.Join(d, "attach_kind.rb")
		os.WriteFile(src, b, 0o644)
		if _, err := Build(cfg, src); err != nil {
			t.Fatal(err)
		}
		if c.name != "control" {
			mp, sp := filepath.Join(d, "attach_kind.mlir"), filepath.Join(d, "attach_kind.schema.json")
			m, _ := os.ReadFile(mp)
			mm := mlirSwap(string(m))
			if mm == string(m) {
				t.Fatalf("%s: the .mlir rewrite did not apply", c.name)
			}
			os.WriteFile(mp, []byte(mm), 0o644)
			if c.schema {
				s, _ := os.ReadFile(sp)
				ss := schemaSwap(string(s))
				if ss == string(s) {
					t.Fatalf("%s: the schema rewrite did not apply", c.name)
				}
				os.WriteFile(sp, []byte(ss), 0o644)
			}
			ec := exec.Command(cfg.EbpfCompile, "attach_kind.mlir", "--schema", "attach_kind.schema.json", "-o", "attach_kind.bpf.o")
			ec.Dir = d
			eo, err := ec.CombinedOutput()
			if !c.schema {
				if err == nil || !strings.Contains(string(eo), `attach "egress" does not match the schema attach_target "ingress"`) {
					t.Errorf("%s: want ebpf-compile to refuse the direction that disagrees with the schema, got %v\n%s", c.name, err, firstLines(string(eo), 3))
				} else {
					t.Logf("%s: detector ebpf-compile — %s", c.name, firstLines(string(eo), 1))
				}
				continue
			}
			if err != nil {
				t.Fatalf("%s: ebpf-compile: %v", c.name, err)
			}
			schema, _ := os.ReadFile(sp)
			sha, err := checkSchemaSHA(filepath.Join(d, "attach_kind.bpf.o"), schema)
			if err != nil {
				t.Fatal(err)
			}
			os.WriteFile(filepath.Join(d, "attach_kind_embed.S"), []byte(embedAsm("attach_kind.bpf.o", sha, "attach_kind.maps.json")), 0o644)
			if err := runIn(d, cfg.Clang, "-c", "-x", "assembler", "attach_kind_embed.S", "-o", "attach_kind_embed.o"); err != nil {
				t.Fatal(err)
			}
		}
		exe := filepath.Join(d, "attach_kind")
		if err := Link(cfg, src, exe); err != nil {
			t.Fatal(err)
		}
		out := feed(t, true, "", exe)
		dir := ""
		for _, l := range strings.Split(out, "\n") {
			if strings.HasPrefix(l, "dir ") {
				dir = l
			}
		}
		t.Logf("%s: %s", c.name, dir)
		want := "dir tc_in=ingress tc_out=egress"
		if c.name != "control" {
			want = "dir tc_in=egress tc_out=egress"
		}
		if dir != want {
			t.Errorf("%s: want %q, got %q", c.name, want, dir)
		}
	}
}
