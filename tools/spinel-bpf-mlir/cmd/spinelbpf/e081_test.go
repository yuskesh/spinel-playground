package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E081 の試験 (P020): uprobe の user 空間 (load の引数の target・attach_uprobe・link の file)・子の process の差動・変異・非 root。

func uprobeSrc(name string) string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", name+".rb")
}

func cfixPath() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", "target", "cfix")
}

// uprobeIntRows は up_ints の `sum A B C` の境界の行 (H2)。
func uprobeIntRows() []string {
	var rows []string
	// −2^63 は外す (E081 の 1 回目: Spinel の to_i が RangeError・library の map_get が INT64_MIN を Spinel の nil の印として ValueRange — 仮説から逸れた)。−2^63 + 1 を代わりに
	for _, a := range []string{"0", "-1", "1099511627776", "-9223372036854775807", "9223372036854775807"} {
		for _, bc := range [][2]string{{"0", "-2147483648"}, {"1", "-1"}, {"4294967295", "0"}, {"4294967295", "2147483647"}} {
			rows = append(rows, "sum "+a+" "+bc[0]+" "+bc[1])
		}
	}
	return rows
}

// uprobeStrRows は up_str の `greet` / `null` の行 (H2 — 普通・空・31 文字・40 文字・NULL)。
func uprobeStrRows() []string {
	return []string{"greet 5 hello", "greet 0", "greet 7 " + strings.Repeat("a", 31), "greet 9 " + strings.Repeat("b", 40), "null 3", "greet 4294967295 x"}
}

// uprobeScript は行ごとに reset・run・dump と (ring が在れば) drain の script。
func uprobeScript(prog string, rows []string, ring string) string {
	var b strings.Builder
	for _, r := range rows {
		b.WriteString("reset\nrun " + prog + " " + r + "\ndump\n")
		if ring != "" {
			b.WriteString("drain " + ring + "\n")
		}
	}
	return b.String()
}

// childTask は kernel の harness の `child` の出力 (子の pid_tgid) から双子の `task` の行を作る (E053 の 2 段)。
func childTask(t *testing.T, kernelOut string) string {
	t.Helper()
	for _, l := range strings.Split(kernelOut, "\n") {
		if strings.HasPrefix(l, "child=") {
			return "task " + strings.TrimPrefix(l, "child=") + "\n"
		}
	}
	t.Fatalf("no child= line in the kernel output:\n%s", firstLines(kernelOut, 5))
	return ""
}

// uprobeCompare は双子と kernel の出力の違う行 (kernel の child の行は呼び手が ok に揃える)。
func uprobeCompare(twin, kernel string) []string {
	tl, kl := strings.Split(twin, "\n"), strings.Split(kernel, "\n")
	var bad []string
	if len(tl) != len(kl) {
		bad = append(bad, "line counts differ: twin "+itoa(len(tl))+", kernel "+itoa(len(kl)))
		return bad
	}
	for i := range tl {
		if tl[i] != kl[i] {
			bad = append(bad, "line "+itoa(i+1)+": twin "+tl[i]+" | kernel "+kl[i])
		}
	}
	return bad
}

// TestUprobeDifferential は E081 の H2 と H3 (host、root): up_ints の整数の境界と up_str の文字列 (普通・空・31・40・NULL) で双子 = kernel、
// status は長さ + 1 / 1 / 32 / 32 / −14、NULL の event の name は空の event と同じ byte (全て 0) で status だけが違う。
func TestUprobeDifferential(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	for _, c := range []struct {
		name, prog, ring string
		rows             []string
	}{
		{"up_ints", "on_sum", "", uprobeIntRows()},
		{"up_str", "on_greet", "Events", uprobeStrRows()},
	} {
		h := buildHarnesses(t, uprobeSrc(c.name))
		script := uprobeScript(c.prog, c.rows, c.ring)
		kn := feed(t, true, "child\n"+script, h.kernelBin, cfixPath())
		tw := feed(t, false, childTask(t, kn)+script, h.twinBin)
		kn = strings.Replace(kn, kn[:strings.Index(kn, "\n")+1], "ok\n", 1) // kernel の child の行と双子の task の ok を揃える
		if os.Getenv("E081_OUT") != "" {
			os.WriteFile(filepath.Join(os.Getenv("E081_OUT"), c.name+".kernel.out"), []byte(kn), 0o644)
			os.WriteFile(filepath.Join(os.Getenv("E081_OUT"), c.name+".twin.out"), []byte(tw), 0o644)
		}
		bad := uprobeCompare(tw, kn)
		for _, b := range first(bad, 8) {
			t.Errorf("%s: %s", c.name, b)
		}
		if strings.Contains(kn, "err=") || strings.Count(kn, "ret=0") != len(c.rows) {
			t.Errorf("%s: unexpected kernel output:\n%s", c.name, firstLines(kn, 20))
		}
		t.Logf("%s: %d rows, %d lines, %d mismatches", c.name, len(c.rows), strings.Count(kn, "\n"), len(bad))
		if c.name != "up_str" {
			continue
		}
		// status と NULL / 空の name (H2)
		st := func(i int) string { return fieldOf(kn, i, "status") }
		nm := func(i int) string { return fieldOf(kn, i, "name") }
		want := []string{"6", "1", "32", "32", "-14", "2"}
		for i, w := range want {
			if st(i) != w {
				t.Errorf("row %d (%s): status %s, want %s", i, c.rows[i], st(i), w)
			}
		}
		if nm(1) != strings.Repeat("00", 32) || nm(4) != nm(1) {
			t.Errorf("the NULL event's name (%s) must be the empty event's bytes (%s) — all zero", nm(4), nm(1))
		}
	}
}

// fieldOf は i 番目の行の drain の `Events#0.<f>=<v>` の v。
func fieldOf(out string, row int, f string) string {
	n := -1
	for _, l := range strings.Split(out, "\n") {
		if l == "Events drained=1" || strings.HasPrefix(l, "Events drained=") {
			continue
		}
		if strings.HasPrefix(l, "Events#0.pid_tgid=") {
			n++
		}
		if n == row && strings.HasPrefix(l, "Events#0."+f+"=") {
			return strings.TrimPrefix(l, "Events#0."+f+"=")
		}
	}
	return ""
}

// linkedUload は testdata/uprobe/uload.rb の実行 file (target の cfix を source の隣に写して build)。
func linkedUload(t *testing.T) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, _ := os.ReadFile(filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "uprobe", "uload.rb"))
	src := filepath.Join(d, "uload.rb")
	os.WriteFile(src, b, 0o644)
	os.MkdirAll(filepath.Join(d, "target"), 0o755)
	fb, _ := os.ReadFile(cfixPath())
	writeExec(t, filepath.Join(d, "target", "cfix"), fb)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "uload")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestUprobeLoadTargets は E081 の H1・H4 (c)・H5 (host): root で load の引数の target の後の unmet 0・attach・link の file が target の path、
// target 無しは binary_unknown・別の build (末尾に 1 byte) は binary で TargetRejected。uid 1000 の CAP_BPF + CAP_PERFMON + CAP_SYS_ADMIN は root と同じ、
// CAP_SYS_ADMIN を外すと attach で止まる。
func TestUprobeLoadTargets(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	exe := linkedUload(t)
	other := filepath.Join(t.TempDir(), "cfix_other")
	fb, _ := os.ReadFile(cfixPath())
	writeExec(t, other, append(append([]byte{}, fb...), 0))
	ok := feed(t, true, "", exe, cfixPath(), "ok")
	// link の file は bml が照合した fd の /proc/self/fd/N (path を開き直さない — 仮説の「target の path」から逸れた、E081 の 1 回目)
	if !strings.Contains(ok, "load ok unmet=0\n") || !strings.Contains(ok, "attach ok file=/proc/self/fd/") || !strings.Contains(ok, "detached\n") {
		t.Errorf("H1: root load / attach / link file:\n%s", ok)
	}
	none := feed(t, true, "", exe, cfixPath(), "none")
	if !strings.Contains(none, "load none kind=SpinelBPF::TargetRejected") || !strings.Contains(none, "Unknown — no binary given") {
		t.Errorf("H1: a load without a target must stop with binary_unknown:\n%s", none)
	}
	ob := feed(t, true, "", exe, other, "ok")
	if !strings.Contains(ob, "load kind=SpinelBPF::TargetRejected") || !strings.Contains(ob, "but the object was built for") || strings.Contains(ob, "load ok") {
		t.Errorf("H1 / H4 (c): another build of the target must stop before load:\n%s", ob)
	}
	nr, err := nonroot(t, "+bpf,+perfmon,+sys_admin", "", exe, cfixPath(), "ok")
	if err != nil || nr != ok {
		t.Errorf("H5: CAP_BPF + CAP_PERFMON + CAP_SYS_ADMIN must match root (err %v):\n%s", err, nr)
	}
	ns, _ := nonroot(t, "+bpf,+perfmon", "", exe, cfixPath(), "ok")
	if !strings.Contains(ns, "load ok unmet=0\n") || !strings.Contains(ns, "attach kind=SpinelBPF::") || strings.Contains(ns, "attach ok") {
		t.Errorf("H5: without CAP_SYS_ADMIN the attach must stop (the load passes):\n%s", ns)
	}
	t.Logf("root:\n%s\nnone:\n%s\nother build:\n%s\nno sys_admin:\n%s", ok, none, ob, ns)
}

// TestUprobeArgSwap は E081 の H4 (a) (host、root): up_ints の .mlir の uprobe.arg の 2 と 3 の入れ替え (型は同じ i32 — ebpf-compile は通す) は
// 差動の Args[1] と Args[2] の行だけを落とす。
func TestUprobeArgSwap(t *testing.T) {
	parallel(t)          // P018 E075
	requireUnverified(t) // E046: 入力の鍵が verified.tsv に在れば skip
	h, cerr := mutatedPkt(t, uprobeSrc("up_ints"), func(s string) (string, bool) {
		a, b := "ebpf.uprobe.arg %ctx 2 :", "ebpf.uprobe.arg %ctx 3 :"
		if strings.Count(s, a) != 1 || strings.Count(s, b) != 1 {
			return s, false
		}
		s = strings.Replace(s, a, "@@2@@", 1)
		s = strings.Replace(s, b, a, 1)
		return strings.Replace(s, "@@2@@", b, 1), true
	})
	if cerr != nil {
		t.Fatalf("ebpf-compile refused the swap: %v", cerr)
	}
	script := uprobeScript("on_sum", uprobeIntRows(), "")
	kn := feed(t, true, "child\n"+script, h.kernelBin, cfixPath())
	tw := feed(t, false, childTask(t, kn)+script, h.twinBin)
	kn = strings.Replace(kn, kn[:strings.Index(kn, "\n")+1], "ok\n", 1)
	bad := uprobeCompare(tw, kn)
	slots := map[string]int{}
	for _, b := range bad {
		if i := strings.Index(b, "twin "); i >= 0 {
			slots[strings.SplitN(b[i+5:], "=", 2)[0]]++
		}
	}
	t.Logf("%d mismatching lines, slots %v", len(bad), slots)
	if len(bad) == 0 || slots["Args[1]"] == 0 || slots["Args[2]"] == 0 || len(slots) != 2 {
		t.Errorf("want mismatches in Args[1] and Args[2] only, got %v", slots)
	}
}
