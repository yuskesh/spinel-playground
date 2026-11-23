package main

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// E121 の試験: lpm_trie (P026 段 ② — F16)。

func lpmData(name string) string {
	return filepath.Join(repoRoot(), "cmd", "spinelbpf", "testdata", "lpm", name)
}

// buildLpmProgram は testdata/lpm の program を build して link した実行 file。link の cfg を変えれば library の写しで link (変異の対照 — build は
// submodule の版を照合するので本物の repo で)。
func buildLpmProgram(t *testing.T, name string, cfg Config, link ...Config) string {
	t.Helper()
	return buildDataProgram(t, lpmData(name+".rb"), cfg, link...)
}

// buildDataProgram は testdata の program (path) を一時の dir で build して link した実行 file (E126 で buildLpmProgram から分けた)。
func buildDataProgram(t *testing.T, path string, cfg Config, link ...Config) string {
	t.Helper()
	d, err := os.MkdirTemp(filepath.Join(repoRoot(), "build", "tmp"), "prog-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	name := strings.TrimSuffix(filepath.Base(path), ".rb")
	src := filepath.Join(d, name+".rb")
	os.WriteFile(src, b, 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, name)
	lc := cfg
	if len(link) > 0 {
		lc = link[0]
	}
	if err := Link(lc, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

func lpmConfig(t *testing.T) Config {
	t.Helper()
	cfg, err := defaultConfig()
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

// TestLpmPrefixNoRoot は E121 H4 の root なしの部分: SpinelBPF.lpm_prefix_len (object 無し — kernel に触らない) の長さと誤りの class。
func TestLpmPrefixNoRoot(t *testing.T) {
	parallel(t)
	exe := buildLpmProgram(t, "lpmprefix", lpmConfig(t))
	want, _ := os.ReadFile(lpmData("lpmprefix.want"))
	if out := feed(t, false, "", exe); out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// TestLpmUserAPI は E121 H4 (追補 1 — root): 往復・最長一致・境界の値・満杯の ENOSPC と上書き・prefix / address の誤り (Other)・ValueRange・NotFound・
// 種類の食い違いの MapMismatch・eBPF の側との行き来 (手で書いた期待 lpmio.want)。
func TestLpmUserAPI(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := buildLpmProgram(t, "lpmio", lpmConfig(t))
	want, _ := os.ReadFile(lpmData("lpmio.want"))
	if out := feed(t, true, "", exe); out != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", out, want)
	}
}

// lpmFrame は宛先の IPv4 を byte 30〜33 に持つ 34 byte の frame の 16 進。
func lpmFrame(a uint32) string {
	b := make([]byte, 34)
	b[30], b[31], b[32], b[33] = byte(a>>24), byte(a>>16), byte(a>>8), byte(a)
	return fmt.Sprintf("%x", b)
}

func ipv4(a uint32) string {
	return fmt.Sprintf("%d.%d.%d.%d", a>>24, a>>16&255, a>>8&255, a&255)
}

func ip(s string) uint32 {
	var a, b, c, d uint32
	fmt.Sscanf(s, "%d.%d.%d.%d", &a, &b, &c, &d)
	return a<<24 | b<<16 | c<<8 | d
}

// tLpmScript は t_lpm の表 (期待の値を持たない — 双子と kernel を比べる)。行は `echo <label>` と reset で始まる。
// lookup は program の test run (Out に写す) と user の側の lpmatch の両方、dump は Out と 3 つの lpm の map (数の順に並べた行)。
func tLpmScript() string {
	var b strings.Builder
	row := func(label string) { fmt.Fprintf(&b, "echo %s\nreset\n", label) }
	put := func(m, p string, v int64) { fmt.Fprintf(&b, "lput %s %s %d\n", m, p, v) }
	look := func(prog, m string, a uint32) {
		fmt.Fprintf(&b, "run %s %s\nlmatch %s %s\nlhas %s %s\ndump\n", prog, lpmFrame(a), m, ipv4(a), m, ipv4(a))
	}
	row("l_bounds") // /0・入れ子 /8 ⊃ /16 ⊃ /24 ⊃ /32・隣の /25・一致無し、remove の後の fallback
	for _, p := range []struct {
		s string
		v int64
	}{{"0.0.0.0/0", 1}, {"10.0.0.0/8", 2}, {"10.1.0.0/16", 3}, {"10.1.2.0/24", 4}, {"10.1.2.3/32", 5}, {"10.1.2.128/25", 6}} {
		put("Big", p.s, p.v)
	}
	for _, a := range []string{"10.1.2.3", "10.1.2.4", "10.1.2.200", "10.1.3.1", "10.2.0.0", "11.0.0.0", "255.255.255.255", "0.0.0.0"} {
		look("t_big", "Big", ip(a))
	}
	fmt.Fprintf(&b, "lremove Big 10.1.2.3/32\nlremove Big 10.1.2.3/32\nlremove Big 10.1.2.0/24\n")
	look("t_big", "Big", ip("10.1.2.3"))
	look("t_big", "Big", ip("10.1.2.200"))
	fmt.Fprintf(&b, "lremove Big 0.0.0.0/0\n")
	look("t_big", "Big", ip("11.0.0.0"))
	row("l_values") // 値 0 (在る) と 0xFFFFFFFF
	put("Big", "192.168.0.0/16", 0)
	put("Big", "192.168.1.0/24", 4294967295)
	look("t_big", "Big", ip("192.168.0.1"))
	look("t_big", "Big", ip("192.168.1.1"))
	look("t_big", "Big", ip("192.169.0.0"))
	row("l_short") // window の外 (33 byte の frame)
	put("Big", "0.0.0.0/0", 9)
	fmt.Fprintf(&b, "run t_big %s\ndump\n", lpmFrame(0)[:66])
	row("l_full") // max_entries 4: 5 つ目の新しい prefix・満杯での上書き・消した後
	for i, p := range []string{"1.0.0.0/8", "2.0.0.0/8", "3.0.0.0/8", "4.0.0.0/8"} {
		put("Small", p, int64(i+1))
	}
	put("Small", "5.0.0.0/8", 5)
	put("Small", "2.0.0.0/8", 20)
	look("t_small", "Small", ip("2.2.2.2"))
	look("t_small", "Small", ip("5.5.5.5"))
	fmt.Fprintf(&b, "lremove Small 1.0.0.0/8\n")
	put("Small", "5.0.0.0/8", 5)
	look("t_small", "Small", ip("5.5.5.5"))
	look("t_small", "Small", ip("1.1.1.1"))
	row("l_neg") // i32 の値 (最小・最大・−1)
	put("Neg", "10.0.0.0/24", -2147483648)
	put("Neg", "10.0.0.128/25", 2147483647)
	put("Neg", "10.0.0.7/32", -1)
	for _, a := range []string{"10.0.0.1", "10.0.0.200", "10.0.0.7", "10.0.1.0"} {
		look("t_neg", "Neg", ip(a))
	}
	row("l_random") // 固定の seed の prefix 64 (同じ prefix は上書き) と address 256 (半分は prefix の中)
	r := rand.New(rand.NewSource(121))
	var pfx []struct{ a, l uint32 }
	for i := 0; i < 64; i++ {
		l := uint32(r.Intn(33))
		a := r.Uint32()
		if l < 32 {
			a &^= (uint32(1)<<(32-l) - 1)
		}
		pfx = append(pfx, struct{ a, l uint32 }{a, l})
		put("Big", fmt.Sprintf("%s/%d", ipv4(a), l), int64(r.Uint32()))
	}
	for i := 0; i < 256; i++ {
		a := r.Uint32()
		if i%2 == 0 {
			p := pfx[r.Intn(len(pfx))]
			if p.l < 32 {
				a = p.a | a&(uint32(1)<<(32-p.l)-1)
			} else {
				a = p.a
			}
		}
		fmt.Fprintf(&b, "run t_big %s\nlmatch Big %s\n", lpmFrame(a), ipv4(a))
	}
	b.WriteString("dump\n")
	return b.String()
}

// TestLpmTable は E121 H5 (host 7.1.8、root、test run だけ): t_lpm の表で双子 (Spinel) と kernel の出力が行ごとに一致、kernel の出力に満杯の −28・上書きの 0・
// remove の後の fallback が意図した行に在る。
func TestLpmTable(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, lpmData("t_lpm.rb"))
	script := tLpmScript()
	tw := feed(t, false, script, h.twinBin)
	kn := feed(t, true, script, h.kernelBin)
	if d := ringDiff(tw, kn); d != "" {
		t.Errorf("twin / kernel: %s", d)
	}
	t.Logf("%d lines", strings.Count(tw, "\n"))
	for _, w := range []string{"## l_bounds\n", "lmatch=5\n", "lremove=0\nlremove=-2\nlremove=0\n", "lmatch=3\n", "## l_full\n", "lput=-28\nlput=0\n", "## l_neg\n", "lmatch=-2147483648\n", "## l_random\n"} {
		i := strings.Index(kn, w)
		if i < 0 {
			t.Fatalf("the kernel output lacks %q in order", w)
		}
		kn = kn[i+len(w):]
	}
}

// TestLpmTableOut は E121 の成果物: 表の手順と kernel の出力を E121_OUT に残す。
func TestLpmTableOut(t *testing.T) {
	parallel(t)
	o := os.Getenv("E121_OUT")
	if o == "" {
		t.Skip("E121_OUT")
	}
	h := buildHarnesses(t, lpmData("t_lpm.rb"))
	script := tLpmScript()
	os.WriteFile(filepath.Join(o, "t_lpm.script"), []byte(script), 0o644)
	os.WriteFile(filepath.Join(o, "t_lpm.kernel.out"), []byte(feed(t, true, script, h.kernelBin)), 0o644)
	os.WriteFile(filepath.Join(o, "t_lpm.twin.out"), []byte(feed(t, false, script, h.twinBin)), 0o644)
}

// spinelSpliceNames は Spinel が source の頭に builtins を継ぎ込む名前 (名前 → 継ぎ込む file)。手で書かず Spinel の source から: sp_splice_builtins が読む
// builtins/enumerable.rb と sp_builtin_extras の表の file の `\n  def <名前>` (sp_builtin_names_from_into と同じ規則 — 無い file は Spinel と同じく飛ばす)、
// aliases の表の綴り (行き先が enumerable に在るものだけ)。
func spinelSpliceNames(t *testing.T) map[string]string {
	t.Helper()
	sp := filepath.Join(repoRoot(), "third_party", "spinel")
	b, err := os.ReadFile(filepath.Join(sp, "src", "spinel_parse.c"))
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	if !strings.Contains(src, `"%.*s/builtins/enumerable.rb"`) {
		t.Fatal("spinel_parse.c does not read builtins/enumerable.rb")
	}
	files := []string{"builtins/enumerable.rb"}
	for _, m := range regexp.MustCompile(`\{ "(builtins/\w+\.rb)", "builtins/\w+", NULL, 0, 0 \}`).FindAllStringSubmatch(src, -1) {
		files = append(files, m[1])
	}
	if len(files) == 1 {
		t.Fatal("spinel_parse.c: the sp_builtin_extras table is not found")
	}
	def := regexp.MustCompile(`\n  def ([A-Za-z0-9_]+[?!]?)`)
	names := map[string]string{}
	for _, f := range files {
		c, err := os.ReadFile(filepath.Join(sp, f))
		if os.IsNotExist(err) {
			continue
		} else if err != nil {
			t.Fatal(err)
		}
		for _, m := range def.FindAllStringSubmatch(string(c), -1) {
			if _, ok := names[m[1]]; !ok {
				names[m[1]] = f
			}
		}
	}
	al := regexp.MustCompile(`aliases\[\]\[2\] = \{(.*)\};`).FindStringSubmatch(src)
	if al == nil {
		t.Fatal("spinel_parse.c: the aliases table is not found")
	}
	for _, m := range regexp.MustCompile(`\{ "(\w+)", "(\w+)" \}`).FindAllStringSubmatch(al[1], -1) {
		if names[m[2]] == "builtins/enumerable.rb" {
			names[m[1]] = "builtins/enumerable.rb"
		}
	}
	if names["count"] != "builtins/enumerable.rb" {
		t.Fatalf("the enumerable names lack count: %d names", len(names))
	}
	return names
}

// spliceMentions は library の source の中で Spinel が builtins を継ぎ込む名前の言及 (file:行 名前 (継ぎ込む file))。条件は Spinel の
// src/spinel_parse.c の sp_source_mentions_method をそのまま写す (E130 追補 3 — E121 の def の名前だけの検査を広げた): 名前の前後が語の境
// (前は英数字・_・@・$・: でない、後は英数字・_・?・!・= でない)、行頭から名前までに `#` が無い (comment — 文字列の中の `#` も comment と見なす Spinel の
// 粗い規則のまま、文字列の中身は除かない)、前が `.` か、後が `(`・空白・改行。def の名前・呼び出し・引数・局所の名前のどれでも当たる。
func spliceMentions(file, src string, names map[string]string) []string {
	isWord := func(c byte) bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' }
	var hits []string
	for name, from := range names {
		for p := 0; ; {
			i := strings.Index(src[p:], name)
			if i < 0 {
				break
			}
			at := p + i
			end := at + len(name)
			p = end
			var ac byte
			if end < len(src) {
				ac = src[end]
			}
			bc := byte(' ')
			if at > 0 {
				bc = src[at-1]
			}
			if isWord(ac) || ac == '?' || ac == '!' || ac == '=' || isWord(bc) || bc == '@' || bc == '$' || bc == ':' {
				continue
			}
			ls := strings.LastIndexByte(src[:at], '\n') + 1
			if strings.IndexByte(src[ls:at], '#') >= 0 {
				continue
			}
			if bc == '.' || ac == '(' || ac == ' ' || ac == '\n' {
				hits = append(hits, fmt.Sprintf("%s:%d %s (%s)", file, strings.Count(src[:at], "\n")+1, name, from))
			}
		}
	}
	sort.Strings(hits)
	return hits
}

// TestLibraryDefsAvoidSpinelSplice は E121 追補 2 / E130 追補 3 (root なし): 双子と本番の library の source が Spinel の builtins の継ぎ込みの名前に
// (Spinel の条件どおりに) 言及しない — 言及すると library を読む全ての program の利用者の file の行がずれる (S11 — E121 の双子の def find、E130 の双子の
// 引数 clamp が TestTwinTypes を落とした)。
func TestLibraryDefsAvoidSpinelSplice(t *testing.T) {
	parallel(t)
	names := spinelSpliceNames(t)
	for _, f := range []string{"ruby/lib/native/bpf.rb", "ruby/lib/bpf.rb", "ruby/lib/spinelbpf.rb"} {
		b, err := os.ReadFile(filepath.Join(repoRoot(), f))
		if err != nil {
			t.Fatal(err)
		}
		for _, h := range spliceMentions(f, string(b), names) {
			t.Errorf("%s — a name Spinel splices builtins for (S11): rename it", h)
		}
	}
}
