package frontend

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// E158 の試験 (P029 §2 段 5): uprobe の :user_buf と R.output_buf (bpf-mlir E560 の user.read)。

// TestUprobeBufPositive は H1: up_buf (pfix の put_buf の buf と len) が生成でき bpf-mlir の道具を通り、build の時の照合の Unmet 0。
// .mlir は `ebpf.uprobe.arg … -> !ebpf.user_buf` と `ebpf.user.read … -> i64, i32`、schema の param は user_buf、requirements は形式 18 で
// `uprobearg on_put 1 ptr` と `uprobearg on_put 2 i32`。
func TestUprobeBufPositive(t *testing.T) {
	sp := testSpinel(t)
	out, err := Generate(sp, t.TempDir(), filepath.Join("testdata", "uprobe", "up_buf.rb"))
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	elf := compileAll(t, out)
	if err := UprobeBuildCheck(elf, out.Result); err != nil {
		t.Errorf("the build-time check refused the :user_buf program: %v", err)
	}
	for _, w := range []string{`ebpf.uprobe.arg %ctx 1 : !ebpf.ctx<"uprobe"> -> !ebpf.user_buf`, `ebpf.user.read `, `!ebpf.user_buf, i64 -> i64, i32`} {
		if !strings.Contains(out.MLIR, w) {
			t.Errorf("the .mlir lacks %q", w)
		}
	}
	if !strings.Contains(string(out.Schema), `"kind": "user_buf"`) {
		t.Errorf("the schema lacks the user_buf parameter type")
	}
	if !bytes.Contains(elf, []byte("ebpf-requirements 18\n")) || !bytes.Contains(elf, []byte("uprobearg\ton_put\t1\tptr\n")) || !bytes.Contains(elf, []byte("uprobearg\ton_put\t2\ti32\n")) {
		t.Errorf("the ELF requirements: want format 18 with `uprobearg on_put 1 ptr` and `uprobearg on_put 2 i32`")
	}
}

// libsslSrc is a uprobe that reads buf and num of libssl's SSL_write(SSL *s, const void *buf, int num) with output_buf (one pair of the bpf-mlir coordinator's i1256).
const libsslSrc = `require "bpf"

W = Struct.new(:pid_tgid, :status, :count, :len, :data)
BPF.record(W, pid_tgid: :u64, status: :i64, count: :i32, len: :i32, data: [:u8, 64])
Writes = BPF::RingBuf.new("Writes", W.new(0, 0, 0, 0, Array.new(64, 0)), 65536)

def on_write(ctx)
  _ = Writes.output_buf(W.new(BPF.pid_tgid, 0, 0, ctx.arg(3), Array.new(64, 0)), :data, ctx.buf_arg(2), ctx.arg(3), :status, :count)
end
BPF.uprobe :on_write, "/usr/lib/x86_64-linux-gnu/libssl.so.3", "SSL_write", params: {2 => :user_buf, 3 => :i32}
`

// TestUprobeBufLibssl is H1's libssl pair (the bpf-mlir coordinator's i1256): libssl's own binary has no DWARF; at build time the match uses libssl3t64-dbgsym's split DWARF
// (debugRoot's default /usr/lib/debug) with Unmet 0, and with debugRoot "" (no search) it stops with SB032's uprobearg_unknown (argument 2's ptr and 3's i32).
func TestUprobeBufLibssl(t *testing.T) {
	sp := testSpinel(t)
	f := filepath.Join(t.TempDir(), "ssl.rb")
	os.WriteFile(f, []byte(libsslSrc), 0o644)
	out, err := Generate(sp, t.TempDir(), f)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	elf := compileAll(t, out)
	if err := UprobeBuildCheck(elf, out.Result); err != nil {
		t.Errorf("with the default debug root the libssl program must pass (is libssl3t64-dbgsym installed for this libssl3t64?): %v", err)
	}
	old := debugRoot
	t.Cleanup(func() { debugRoot = old })
	debugRoot = ""
	err = UprobeBuildCheck(elf, out.Result)
	t.Logf("%v", err)
	var e *Error
	if !errors.As(err, &e) || len(e.Diags) != 1 || e.Diags[0].Code != SB032UprobeTarget || e.Diags[0].Pos.Line != 10 {
		t.Fatalf("with the debug root off want one SB032 at the declaration (line 10), got %v", err)
	}
	for _, w := range []string{"uprobearg_unknown 2 of SSL_write (ptr)", "uprobearg_unknown 3 of SSL_write (i32)"} {
		if !strings.Contains(e.Diags[0].Msg, w) {
			t.Errorf("want %q in %s", w, e.Diags[0].Msg)
		}
	}
}
