//go:build linux

package main

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/asm"
	"github.com/cilium/ebpf/rlimit"
)

// --- 権限が要らない検査 ------------------------------------------------------

// **positive**: バイナリの中に ELF magic があること (= 埋め込まれている)。
func TestEmbeddedELFMagic(t *testing.T) {
	elf := ObjectELF()
	if len(elf) < 4 || !bytes.Equal(elf[:4], []byte{0x7f, 'E', 'L', 'F'}) {
		t.Fatalf("埋め込み ELF の magic がおかしい: %x", elf[:min(4, len(elf))])
	}
	if len(elf) < 1024 {
		t.Errorf("埋め込み ELF が小さすぎる (%d バイト)", len(elf))
	}
}

// **negative の対照**: 隣に .bpf.o が無くても起動すること。
// バイナリだけを空のディレクトリへ写して走らせる。
func TestStartsWithoutAdjacentObject(t *testing.T) {
	goBin := goBinary()
	dir := t.TempDir()
	bin := filepath.Join(dir, "xdp-counter")
	build := exec.Command(goBin, "build", "-o", bin, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	// 隣に .bpf.o が無いことを確かめてから走らせる。
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".bpf.o") {
			t.Fatalf("一時ディレクトリに %s が居る — 対照になっていない", e.Name())
		}
	}
	out, err := exec.Command(bin, "-parse-only").CombinedOutput()
	if err != nil {
		t.Fatalf("隣に .bpf.o が無いと起動できない: %v\n%s", err, out)
	}
	if !strings.HasPrefix(string(out), "parse-ok ") {
		t.Errorf("想定外の出力: %s", out)
	}
}

// --- kernel に触る検査 (権限が無ければ skip) ----------------------------------

func requireBPF(t *testing.T) {
	t.Helper()
	if err := rlimit.RemoveMemlock(); err != nil {
		t.Skipf("BPF を使う権限が無い: %v", err)
	}
	spec, err := LoadCollectionSpec()
	if err != nil {
		t.Fatalf("埋め込み ELF を parse できない: %v", err)
	}
	var objs Objects
	if err := spec.LoadAndAssign(&objs, nil); err != nil {
		t.Skipf("kernel に load できない (CAP_BPF + CAP_NET_ADMIN が要る): %v", err)
	}
	objs.Close()
}

// load して close したあと、この program が残っていないこと。
func TestLoadAndCloseLeavesNothing(t *testing.T) {
	requireBPF(t)
	var objs Objects
	if err := LoadObjects(&objs, nil); err != nil {
		t.Fatalf("load: %v", err)
	}
	if objs.CountPackets == nil || objs.Counts == nil || objs.Events == nil {
		t.Fatal("Objects の割り当てが埋まっていない")
	}
	if err := objs.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	// close 済みの handle は再利用できないこと (二重 close の検出)。
	if err := objs.Close(); err == nil {
		t.Log("二重 close はエラーにならない (cilium/ebpf の仕様)")
	}
}

// **verifier の拒否を素の -EACCES で終わらせないこと** (P013 Task 6 checkbox)。
//
// 対照は E153 で実際に踏んだ欠陥そのもの: xdp_md の data_end を **8 バイトで読む**。
// 正しくは u32 で読んで pointer へ広げる。ここは回帰テストでもある。
func TestVerifierRejectionIsExplained(t *testing.T) {
	requireBPF(t)
	spec, err := LoadCollectionSpec()
	if err != nil {
		t.Fatal(err)
	}
	prog := spec.Programs["count_packets"]
	// ctx+4 を 8 バイトで読む = `invalid bpf_context access off=4 size=8`。
	prog.Instructions = asm.Instructions{
		asm.LoadMem(asm.R2, asm.R1, 4, asm.DWord),
		asm.Mov.Imm(asm.R0, 2),
		asm.Return(),
	}
	var objs Objects
	err = spec.LoadAndAssign(&objs, nil)
	if err == nil {
		objs.Close()
		t.Fatal("壊した program が通ってしまった")
	}
	var ve *ebpf.VerifierError
	if !errors.As(err, &ve) {
		t.Fatalf("VerifierError ではない: %T %v", err, err)
	}

	msg := explainLoadError(err)
	for _, want := range []string{
		"count_packets",     // どの program か
		"schema",            // 正典がどこか
		"xdp_counter.mlir",  // 生成元がどこか
		"bpfgen/main.go",    // その生成元がどこか
	} {
		if !strings.Contains(msg, want) {
			t.Errorf("診断に %q が出ていない:\n%s", want, msg)
		}
	}
	if !strings.Contains(msg, "invalid bpf_context access") {
		t.Errorf("kernel の言い分が診断に入っていない:\n%s", msg)
	}
}

func goBinary() string {
	if g := os.Getenv("GO"); g != "" {
		return g
	}
	return "go"
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
