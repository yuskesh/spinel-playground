package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E158 の試験 (P029 §2 段 5 — uprobe の :user_buf と R.output_buf): 双子の smoke・子の pfix の差動 (H3)・変異 (H4 — e158_mutation_test.go)・sslsniff (H5)。

func pfixPath() string {
	return filepath.Join(repoRoot(), "internal", "frontend", "testdata", "uprobe", "target", "pfix")
}

// bufRows は H3 の pfix の行: 普通・長さ 0・ちょうど 64・clamp (100 → 64)・負の長さ・NULL。
var bufRows = []string{"put 5 hello", "put 0 x", "put 64 " + strings.Repeat("a", 64), "put 100 " + strings.Repeat("b", 70), "put -5 abc", "putnull 8"}

// bufScript は行ごとに run と drain の script (双子と kernel で同じ — 双子は pfix の命令を自分で解く)。
func bufScript() string {
	var b strings.Builder
	b.WriteString("reset\n")
	for _, r := range bufRows {
		b.WriteString("run on_put " + r + "\ndrain Writes\n")
	}
	b.WriteString("dump\n")
	return b.String()
}

// bufDiff は 2 段の差動 (kernel は子の pfix に命令を送る、双子は child の task で同じ script) — child の行を揃えた kernel と双子の出力。
func bufDiff(t *testing.T) (kernel, twin string) {
	t.Helper()
	h := buildHarnesses(t, uprobeSrc("up_buf"))
	kn := feed(t, true, "child\n"+bufScript(), h.kernelBin, pfixPath())
	tw := feed(t, false, childTask(t, kn)+bufScript(), h.twinBin)
	return strings.Replace(kn, kn[:strings.Index(kn, "\n")+1], "ok\n", 1), tw
}

// TestUprobeBufTwinSmoke は H3 の非 root の部分: 双子の output_buf の clamp・ゼロ化・NULL の status。
func TestUprobeBufTwinSmoke(t *testing.T) {
	parallel(t)
	requireUnverified(t)
	h := buildHarnesses(t, uprobeSrc("up_buf"))
	out := feed(t, false, "task 4294967297\n"+bufScript(), h.twinBin)
	t.Log(out)
	for _, w := range []string{"Writes#0.count=5\n", "Writes#0.count=0\n", "Writes#0.count=64\n", "Writes#0.len=100\n", "Writes#0.len=-5\n", "Writes#0.status=-14\nWrites#0.count=8\n", "Out[0]=6\n", "Out[1]=0\n"} {
		if !strings.Contains(out, w) {
			t.Errorf("twin: want %q", w)
		}
	}
}

// TestUprobeBufDifferential は H3 (root): 子の pfix の pid に attach した kernel の 6 つの event (status・count・len・data) と Out が双子と byte で同じ。
// 予測: count 5 / 0 / 64 / 64 / 0 / 8、status 0 / 0 / 0 / 0 / 0 / −14 (n = 0 の probe_read_user は 0、NULL は −EFAULT)。
func TestUprobeBufDifferential(t *testing.T) {
	requireUnverified(t)
	kn, tw := bufDiff(t)
	if os.Getenv("E158_OUT") != "" {
		os.WriteFile(filepath.Join(os.Getenv("E158_OUT"), "buf.kernel.out"), []byte(kn), 0o644)
		os.WriteFile(filepath.Join(os.Getenv("E158_OUT"), "buf.twin.out"), []byte(tw), 0o644)
	}
	t.Log(kn)
	bad := uprobeCompare(tw, kn)
	for _, b := range first(bad, 8) {
		t.Errorf("%s", b)
	}
	var counts, statuses []string
	for _, l := range strings.Split(kn, "\n") {
		if strings.HasPrefix(l, "Writes#0.count=") {
			counts = append(counts, strings.TrimPrefix(l, "Writes#0.count="))
		}
		if strings.HasPrefix(l, "Writes#0.status=") {
			statuses = append(statuses, strings.TrimPrefix(l, "Writes#0.status="))
		}
	}
	if strings.Join(counts, " ") != "5 0 64 64 0 8" || strings.Join(statuses, " ") != "0 0 0 0 0 -14" {
		t.Errorf("kernel counts %v (want 5 0 64 64 0 8), statuses %v (want 0 0 0 0 0 -14)", counts, statuses)
	}
}

// bccLibsslSHA は sslsniff の生成物の再現の条件: host の libssl.so.3 (libssl3t64 3.5.7-1~deb13u3) の SHA-256 (schema の binary_sha256 に入る —
// examples/bcc/README.md)。
const bccLibsslSHA = "9592038e92d1f41affcbb625334d0b6e788714c889104fa6d5b107cf9fd657f2"

// TestBccLibsslCondition は sslsniff の生成物の一致 (TestBccArtefacts/sslsniff) の前提の host の libssl を名指しで照らす (E156 の TestBccLibcCondition と同じ形)。
func TestBccLibsslCondition(t *testing.T) {
	parallel(t)
	h, err := shaFile("/usr/lib/x86_64-linux-gnu/libssl.so.3")
	if err != nil || h != bccLibsslSHA {
		t.Errorf("the host libssl /usr/lib/x86_64-linux-gnu/libssl.so.3 has sha256 %s (%v), not the reproduction condition %s (libssl3t64 3.5.7-1~deb13u3) — the sslsniff artefacts embed the libssl hash, so TestBccArtefacts/sslsniff differs too (examples/bcc/README.md)", h, err, bccLibsslSHA)
	}
}

// TestBccSelftestSslsniff は H5 (root): --selftest (自分の pid だけに attach — 自分の SSL_write の平文 24 byte)。bccSelftest の実用の形
// (--duration-ms — pid 0) は sslsniff の口が受けない (--pid 必須) ので走らせない。
func TestBccSelftestSslsniff(t *testing.T) {
	requireUnverified(t)
	cfg, _ := defaultConfig()
	d := t.TempDir()
	src := bccSource(t, d, "bcc/sslsniff")
	if _, err := Build(cfg, src); err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(d, "sslsniff")
	if err := Link(cfg, src, exe); err != nil {
		t.Fatal(err)
	}
	out := feed(t, true, "", exe, "--selftest")
	t.Log(out)
	if !strings.Contains(out, "selftest ok") || !strings.Contains(out, "spinel-sslsniff-selftest") {
		t.Errorf("--selftest: want %q and the plaintext in the output", "selftest ok")
	}
}
