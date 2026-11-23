package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/yuskesh/spinel-playground/tools/spinel-bpf-mlir/internal/frontend"
)

// E156 の試験 (P029 §2 段 3 — system の library の uprobe): libc の getaddrinfo の双子の smoke・子の gfix の差動 (H4)・load の時の
// 分けた DWARF の root (H5 — UprobeTargets#debug_root)。

func gfixPath() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", "target", "gfix")
}

// gaiHarnesses は buildHarnesses (e009) と同じ双子と kernel の harness — target は絶対の path (libc) をその場で読むので、kernel の harness に source の
// dir を渡さない (buildKernelHarness の相対の target の写しを外す — e009 の共有の helper を変えない)。
func gaiHarnesses(t *testing.T) harnessSet {
	t.Helper()
	cfg, _ := defaultConfig()
	src := uprobeSrc("up_libc_gai")
	text, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	sp := frontend.Spinel{Bin: cfg.Spinel, LibDir: filepath.Join(cfg.Repo, "ruby", "lib")}
	res, err := frontend.Analyze(sp, t.TempDir(), src, string(text))
	if err != nil || res.Diags.Blocking() {
		t.Fatalf("analyze: %v %v", err, res.Diags)
	}
	tw, err := frontend.TwinHarness(string(text), res)
	if err != nil {
		t.Fatal(err)
	}
	td := t.TempDir()
	twinSrc := filepath.Join(td, "up_libc_gai.rb")
	os.WriteFile(twinSrc, []byte(tw), 0o644)
	twinBin := filepath.Join(td, "twin")
	c := exec.Command(cfg.Spinel, "-I", filepath.Join(cfg.Repo, "ruby", "lib", "native"), "up_libc_gai.rb", "-o", twinBin)
	c.Dir, c.Env = td, append(os.Environ(), "TMPDIR="+td)
	if o, err := c.CombinedOutput(); err != nil {
		t.Fatalf("building the twin harness: %v\n%s", err, o)
	}
	return harnessSet{twinBin: twinBin, twinSrc: twinSrc, kernelBin: buildKernelHarness(t, cfg, "up_libc_gai.rb", string(text), res)}
}

// gaiRows は H4 の gfix の命令 (AI_NUMERICHOST — 網に出ない、999.1.1.1 は EAI_NONAME = -2)。
var gaiRows = []string{"gai 127.0.0.1 80", "gai 127.0.0.1 80", "gai 999.1.1.1 80"}

// TestGaiTwinSmoke は H4 の非 root の部分: 双子の on_gai の `gai HOST SERV` は host を引数 1 の文字列に (status は NUL 込みの長さ)、
// 続く on_gai_ret は Start の入口を見つけて Rets に ret を出し Start から消す。
func TestGaiTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := gaiHarnesses(t)
	out := feed(t, false, "task 4294967297\nreset\nrun on_gai gai 127.0.0.1 80\nrun on_gai_ret ret=-2\ndump\ndrain Calls\ndrain Rets\n", h.twinBin)
	t.Log(out)
	wantLines(t, out, "Out[0]=1", "Out[1]=1", "Out[2]=0", "Calls#0.status=10", "Rets#0.ret=-2")
	if strings.Contains(out, "Start[") {
		t.Errorf("on_gai_ret must delete the Start entry:\n%s", out)
	}
}

// gaiCopyNs は双子の Rets#0.ns の行を kernel の同じ順の行に替える (時間の値は kernel の値を写す — H4、kernel の値は > 0 を見る)。
func gaiCopyNs(t *testing.T, twin, kernel string) string {
	t.Helper()
	var ks []string
	for _, l := range strings.Split(kernel, "\n") {
		if strings.HasPrefix(l, "Rets#0.ns=") {
			if v := strings.TrimPrefix(l, "Rets#0.ns="); strings.HasPrefix(v, "-") || v == "0" {
				t.Errorf("kernel latency %s, want > 0", v)
			}
			ks = append(ks, l)
		}
	}
	tl := strings.Split(twin, "\n")
	n := 0
	for i, l := range tl {
		if strings.HasPrefix(l, "Rets#0.ns=") {
			if n >= len(ks) {
				t.Fatalf("the twin has more Rets events than the kernel (%d)", len(ks))
			}
			tl[i] = ks[n]
			n++
		}
	}
	if n != len(ks) {
		t.Errorf("Rets events: twin %d, kernel %d", n, len(ks))
	}
	return strings.Join(tl, "\n")
}

// TestGaiDifferential は H4 (root): 子の gfix の pid に attach した kernel (libc の getaddrinfo の uprobe と uretprobe — load の分けた DWARF は
// 既定の /usr/lib/debug — H5 (a) の既定) と、子の答えを挟んだ双子の、Calls の host・status と Rets の ret・Out・件数が byte で同じ。
func TestGaiDifferential(t *testing.T) {
	requireUnverified(t)
	h := gaiHarnesses(t)
	var ks strings.Builder
	ks.WriteString("child\nreset\n")
	for _, r := range gaiRows {
		fmt.Fprintf(&ks, "run on_gai_ret %s\ndrain Calls\ndrain Rets\n", r)
	}
	ks.WriteString("dump\n")
	kn := feed(t, true, ks.String(), h.kernelBin, gfixPath())
	var rvs []string
	for _, l := range strings.Split(kn, "\n") {
		if strings.HasPrefix(l, "rv=") {
			rvs = append(rvs, strings.TrimPrefix(l, "rv="))
		}
	}
	if strings.Join(rvs, " ") != "0 0 -2" {
		t.Fatalf("the child's answers %v, want 0 0 -2:\n%s", rvs, kn)
	}
	var ts strings.Builder
	ts.WriteString(childTask(t, kn) + "reset\n")
	for i, r := range gaiRows {
		fmt.Fprintf(&ts, "run on_gai %s\nrun on_gai_ret ret=%s\ndrain Calls\ndrain Rets\n", r, rvs[i])
	}
	ts.WriteString("dump\n")
	tw := feed(t, false, ts.String(), h.twinBin)
	if os.Getenv("E156_OUT") != "" {
		os.WriteFile(filepath.Join(os.Getenv("E156_OUT"), "gai.kernel.out"), []byte(kn), 0o644)
		os.WriteFile(filepath.Join(os.Getenv("E156_OUT"), "gai.twin.out"), []byte(tw), 0o644)
	}
	// kernel の 1 つの run は双子の 2 つの run (入口と戻り) — child と rv の行を双子の形に揃える
	var kl []string
	for _, l := range strings.Split(kn, "\n") {
		if strings.HasPrefix(l, "child=") {
			l = "ok"
		}
		if strings.HasPrefix(l, "rv=") {
			continue
		}
		kl = append(kl, l)
		if l == "ret=0" {
			kl = append(kl, "ret=0")
		}
	}
	kn2 := strings.Join(kl, "\n")
	tw = gaiCopyNs(t, tw, kn2)
	bad := uprobeCompare(tw, kn2)
	for _, b := range first(bad, 8) {
		t.Errorf("%s", b)
	}
	t.Logf("%d rows, %d mismatches\n%s", len(gaiRows), len(bad), kn)
	for _, w := range []string{"Out[0]=3", "Out[1]=3", "Out[2]=0"} {
		if !strings.Contains(kn, w+"\n") {
			t.Errorf("kernel: want %s", w)
		}
	}
	if strings.Count(kn, "Calls#0.status=10\n") != 3 || strings.Count(kn, "Rets#0.ret=0\n") != 2 || strings.Count(kn, "Rets#0.ret=-2\n") != 1 {
		t.Errorf("kernel: want 3 entry events with status 10 and returns 0, 0, -2")
	}
}

// debugRootSrc は up_libc_gai の eBPF の側と、UprobeTargets#debug_root の口を ARGV[0] の mode で選ぶ user の側 (H5)。
//
//	json / json_usr / json_empty / quote   targets の JSON を印字するだけ (非 root)
//	default / usr / empty / dir DIR        load だけ (root — attach しない)
const debugRootUser = `
require "spinelbpf"

mode = ARGV[0]
tg = SpinelBPF::UprobeTargets.new
tg.add("on_gai", "/lib/x86_64-linux-gnu/libc.so.6")
tg.add("on_gai_ret", "/lib/x86_64-linux-gnu/libc.so.6")
if mode == "usr" || mode == "json_usr"
  tg.debug_root("/usr/lib/debug")
elsif mode == "empty" || mode == "json_empty"
  tg.debug_root("")
elsif mode == "dir"
  tg.debug_root(ARGV[1])
end
if mode == "quote"
  begin
    tg.debug_root("a\"b")
    puts tg.json
  rescue SpinelBPF::Error => e
    puts "json kind=#{e.class}"
  end
elsif mode == "json" || mode == "json_usr" || mode == "json_empty"
  puts tg.json
else
  begin
    obj = SpinelBPF.load_embedded_targets(SpinelBPF::ConfigSet.new, tg)
    puts "load ok unmet=#{obj.unmet.length}"
    obj.close
  rescue SpinelBPF::Error => e
    puts "load kind=#{e.class} msg=#{e.message}"
  end
end
`

// debugRootBuild は debugRootSrc の実行 file (build の時の照合は既定の /usr/lib/debug — 通る)。
func debugRootBuild(t *testing.T) string {
	t.Helper()
	cfg, _ := defaultConfig()
	d := t.TempDir()
	b, err := os.ReadFile(uprobeSrc("up_libc_gai"))
	if err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(d, "droot.rb")
	os.WriteFile(src, append(b, []byte(debugRootUser)...), 0o644)
	if _, err := Build(cfg, src); err != nil {
		t.Fatalf("build: %v", err)
	}
	exe := filepath.Join(d, "droot")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	return exe
}

// TestDebugRootJSON は H5 の非 root の部分: debug_root を呼ばなければ JSON に debug_root が無く (bml の既定 /usr/lib/debug)、呼べば
// 空文字も含めて書き、引用符を含む値は ValueRange で拒む。
func TestDebugRootJSON(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	exe := debugRootBuild(t)
	tg := `{"uprobe_targets": [{"program": "on_gai", "path": "/lib/x86_64-linux-gnu/libc.so.6"}, {"program": "on_gai_ret", "path": "/lib/x86_64-linux-gnu/libc.so.6"}]`
	for mode, want := range map[string]string{
		"json":       tg + "}\n",
		"json_usr":   tg + `, "debug_root": "/usr/lib/debug"}` + "\n",
		"json_empty": tg + `, "debug_root": ""}` + "\n",
		"quote":      "json kind=SpinelBPF::ValueRange\n",
	} {
		if out := feed(t, false, "", exe, mode); out != want {
			t.Errorf("%s: got %q, want %q", mode, out, want)
		}
	}
}

// TestDebugRootLoad は H5 (root — load だけ、attach しない): 既定と明示の /usr/lib/debug は load が通り、明示の "" と空の一時の dir は
// bml の照合が TargetRejected で止める (on_gai の uprobearg_unknown と on_gai_ret の uretprobe_abi_unknown — bml src/req/unmet.c の固定の文)。
func TestDebugRootLoad(t *testing.T) {
	requireUnverified(t)
	exe := debugRootBuild(t)
	empty := t.TempDir()
	os.Chmod(empty, 0o755)
	for _, c := range []struct {
		name string
		args []string
		ok   bool
	}{
		{"default", []string{"default"}, true},
		{"usr", []string{"usr"}, true},
		{"empty", []string{"empty"}, false},
		{"dir", []string{"dir", empty}, false},
	} {
		out := feed(t, true, "", append([]string{exe}, c.args...)...)
		t.Logf("%s: %s", c.name, out)
		if c.ok {
			if !strings.HasPrefix(out, "load ok unmet=") {
				t.Errorf("%s: want the load to pass, got %s", c.name, out)
			}
			continue
		}
		if !strings.Contains(out, "load kind=SpinelBPF::TargetRejected") ||
			!strings.Contains(out, "program on_gai reads argument 1 of getaddrinfo (strptr) as a typed value; the binary's DWARF cannot confirm it") || // 停止 A の後に直した (bml の `argument %s` の %s は "1 of getaddrinfo (strptr)")
			!strings.Contains(out, "program on_gai_ret reads the return value of getaddrinfo from the SysV return value register; the binary's DWARF cannot confirm the calling convention") {
			t.Errorf("%s: want TargetRejected naming uprobearg_unknown (on_gai) and uretprobe_abi_unknown (on_gai_ret), got %s", c.name, out)
		}
	}
}

// bccLibcSHA は libc を target にする tool (gethostlatency) の生成物の再現の条件: host の libc.so.6 (libc6 2.41-12+deb13u4) の SHA-256
// (schema の binary_sha256 に入る — examples/bcc/README.md)。
const bccLibcSHA = "9792e3cbb541c8f44c7acf5f14f4022ea62998ecc787d326bed4d8b6547dfd92"

// TestBccLibcCondition is the bpf-mlir coordinator's note i1168: it names and checks the host libc that gethostlatency's artefact match (TestBccArtefacts) assumes
// (TestBccArtefacts's file (e133) is shared per tool key and stays unchanged; the reason for a failure is in this test's message, and it fails beside TestBccArtefacts/gethostlatency).
func TestBccLibcCondition(t *testing.T) {
	parallel(t)
	h, err := shaFile("/lib/x86_64-linux-gnu/libc.so.6")
	if err != nil || h != bccLibcSHA {
		t.Errorf("the host libc /lib/x86_64-linux-gnu/libc.so.6 has sha256 %s (%v), not the reproduction condition %s (libc6 2.41-12+deb13u4) — the gethostlatency artefacts embed the libc hash, so TestBccArtefacts/gethostlatency differs too (examples/bcc/README.md)", h, err, bccLibcSHA)
	}
}

// TestBccSelftestGethostlatency は H7 (root): --selftest (自分の pid だけに attach — 自分の getaddrinfo の 3 回の入口と戻り)。
// bccSelftest の実用の形 (--duration-ms — pid 0 は全ての process の libc に attach) は system に作用する attach なので走らせない (E156 の約束)。
func TestBccSelftestGethostlatency(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/gethostlatency")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "gethostlatency")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "selftest ok") || !strings.Contains(out, "127.0.0.1") {
		t.Errorf("--selftest: want %q and the host 127.0.0.1 in the output", "selftest ok")
	}
}
