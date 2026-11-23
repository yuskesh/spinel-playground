package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/cilium/ebpf"
)

// **非 root で ELF を parse できること** (P013 Task 5 checkbox)。
// kernel には触らない。`__spbpf_record_*` の witness section を cilium/ebpf が
// 黙って無視するかは、ここが最初の実測になる (E151 の申し送り)。
func TestLoadCollectionSpecNonRoot(t *testing.T) {
	spec, err := LoadCollectionSpec()
	if err != nil {
		t.Fatalf("埋め込み ELF を parse できない: %v", err)
	}
	if _, ok := spec.Programs["count_packets"]; !ok {
		t.Errorf("program count_packets が無い (在るのは %v)", keys(spec.Programs))
	}
	for _, want := range []string{"counts", "events"} {
		if _, ok := spec.Maps[want]; !ok {
			t.Errorf("map %q が無い (在るのは %v)", want, keys(spec.Maps))
		}
	}
	if got := spec.Programs["count_packets"].Type; got != ebpf.XDP {
		t.Errorf("program type = %v, want XDP", got)
	}
	if got := spec.Maps["counts"].Type; got != ebpf.Array {
		t.Errorf("counts の type = %v, want Array", got)
	}
	if got := spec.Maps["events"].Type; got != ebpf.RingBuf {
		t.Errorf("events の type = %v, want RingBuf", got)
	}
	// schema の max_entries が BTF 経由で届いていること。
	if got := spec.Maps["events"].MaxEntries; got != 262144 {
		t.Errorf("events の MaxEntries = %d, want 262144", got)
	}
}

// record の decode が schema の offset どおりであること。
// **Go の struct 詰め規則ではなく schema が正典**である (E432 の穴)。
func TestRecordDecodeUsesSchemaOffsets(t *testing.T) {
	b := make([]byte, SizeEvent)
	// hdr.kind = 7 @0, hdr.ts = 0x1122334455667788 @8
	b[0] = 7
	for i := 0; i < 8; i++ {
		b[8+i] = byte(0x88 - i*0x11)
	}
	copy(b[16:32], "spinel\x00")           // comm @16 (16 バイト)
	b[32] = 0x2a                            // pid @32
	b[40] = 0x63                            // duration_ns @40

	var ev Event
	if err := ev.Decode(b); err != nil {
		t.Fatalf("Decode: %v", err)
	}
	if ev.Hdr.Kind != 7 {
		t.Errorf("Hdr.Kind = %d, want 7", ev.Hdr.Kind)
	}
	if ev.Hdr.Ts != 0x1122334455667788 {
		t.Errorf("Hdr.Ts = %#x, want 0x1122334455667788", ev.Hdr.Ts)
	}
	if got := ev.CommString(); got != "spinel" {
		t.Errorf("Comm = %q, want %q", got, "spinel")
	}
	if ev.Pid != 42 {
		t.Errorf("Pid = %d, want 42 (offset 32 — ここが E432 でずれた形)", ev.Pid)
	}
	if ev.DurationNs != 0x63 {
		t.Errorf("DurationNs = %#x, want 0x63", ev.DurationNs)
	}
}

// **依存 scan**: この package の推移的依存に cgo を要求するものが無いこと
// (P013 Global Constraints「Go 経路に MLIR/clang/C/cgo を要求しない」の機械化)。
func TestNoCgoDependency(t *testing.T) {
	// F-10 (E152 Mac 検収): Linux の /usr/local/go 直書きは darwin で存在しない。
	// このテスト自身を走らせている toolchain の go を GOROOT から引く
	// (GO 環境変数 > runtime.GOROOT()/bin/go の順。PATH に依存しない点は方針どおり)。
	goBin := os.Getenv("GO")
	if goBin == "" {
		goBin = filepath.Join(runtime.GOROOT(), "bin", "go")
	}
	// CGO_ENABLED=0 でも建つこと自体が「cgo を要求しない」の実体だが、
	// **依存に cgo を持つ package が居ないこと**も見る (CGO_ENABLED=1 の既定で
	// 引かれてしまう経路を塞ぐため — net.InterfaceByName で実際に踏んだ)。
	cmd := exec.Command(goBin, "list", "-deps",
		"-f", "{{.ImportPath}} {{len .CgoFiles}}", ".")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps: %v\n%s", err, out)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && f[1] != "0" {
			t.Errorf("cgo を使う依存がある: %s (CgoFiles=%s)", f[0], f[1])
		}
		if f[0] == "C" {
			t.Errorf("cgo (import \"C\") を引いている")
		}
	}
	// MLIR / clang を実行時に引いていないこと。
	// **自分のモジュール名に "llvm" が入っている** ("spinel-llvm/...") ので、
	// 素朴な部分一致だと自分を誤検出する。外部依存だけを見る。
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		path := strings.Fields(line)[0]
		if strings.HasPrefix(path, "spinel-llvm/") {
			continue // 自分のモジュール
		}
		low := strings.ToLower(path)
		if strings.Contains(low, "mlir") || strings.Contains(low, "llvm") ||
			strings.Contains(low, "clang") {
			t.Errorf("実行時依存に compiler 側のものが混ざっている: %s", path)
		}
	}
}

// CGO_ENABLED=0 で建つこと。単一 Go バイナリという主張の実体。
// F-11 (E153 Mac 検収): main.go は //go:build linux なので、host が darwin だと
// 「main が無い」で落ちていた。このバイナリの対象は Linux なのだから
// **GOOS=linux のクロスコンパイル**で検査する — cgo を要する依存が混ざれば
// CGO_ENABLED=0 のクロスコンパイルは確実に失敗するので、主張の検査としても強くなる。
func TestBuildsWithoutCgo(t *testing.T) {
	goBin := os.Getenv("GO")
	if goBin == "" {
		goBin = filepath.Join(runtime.GOROOT(), "bin", "go")
	}
	cmd := exec.Command(goBin, "build", "-o", filepath.Join(t.TempDir(), "b"), ".")
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS=linux")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("CGO_ENABLED=0 GOOS=linux で建たない: %v\n%s", err, out)
	}
}

func keys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
