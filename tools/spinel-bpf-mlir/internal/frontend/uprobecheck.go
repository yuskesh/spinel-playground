package frontend

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/yuskesh/go-bpf-mlir/bindrt"
	"github.com/yuskesh/go-bpf-mlir/requirements"
)

// build の時の uprobe の照合 (P020 E080 — 早い誤りの便利: load の時の bml の照合を置き換えない。build の machine と実行の machine の target は
// sha で結ぶ)。bpf-mlir の bindrt の CheckTarget を「uprobe の問いだけ答える caps」で走らせ、Unmet を 3 つに分ける:
// binary から読める 14 種類 (uprobe の 7・E107 の uretprobe と USDT の 5・E156 の分けた DWARF の 2) は宣言の位置の SB032、kernel と loader の能力の 58 種類は無視 (build は kernel を知らない)、どちらにも無い種類は SB032 で止める
// (fail closed — bpf-mlir が種類を足したら build が止まる — mojo-bpf-mlir E085 のレビューの (1))。

// UprobeBuildKinds は build の時に止める uprobe の Unmet の種類 (bpf-mlir requirements_format.md §6)。
var UprobeBuildKinds = map[string]bool{
	"binary": true, "binary_unknown": true, "uprobe_symbol": true, "uprobearg": true, "uprobearg_unknown": true, "uprobearg_abi": true, "uprobearg_abi_unknown": true,
	// E107 (bpf-mlir v1.10.0): binary から build が読める種類 — uretprobe の戻り値の ABI と USDT の点 (spinel は今は出さない)
	"uretprobe_abi": true, "uretprobe_abi_unknown": true, "usdt_probe": true, "usdtarg": true, "usdtarg_unknown": true,
	// E156 (bpf-mlir v1.17.0 — E557): 分けた DWARF の file が本体の build ID・debuglink の CRC と違う (build の machine の file から読める)
	"uprobe_debug_build_id": true, "uprobe_debug_crc": true,
}

// UprobeBuildIgnored は build の時に無視する Unmet の種類 — kernel の能力の問い (build の caps は program type と map type に「無い」、helper に
// ErrUnknown と答え、他の任意の問いに答えない)。load の時は bml が実の kernel で全てを照合する。
var UprobeBuildIgnored = map[string]bool{
	// E165 (bpf-mlir e0a98646d の 28 の種類 — 全て kernel / loader の能力の問い、spinel の ELF は今これらの行を持たない):
	"arena_loader": true, "arena_loader_unknown": true, "attach_netkit_unknown": true, "coreenum": true, "coreenum_unknown": true, "datakptr_loader": true, "datakptr_loader_unknown": true,
	"enumval": true, "enumval_unknown": true, "fibflags": true, "fibflags_unknown": true, "funcret": true, "funcret_unknown": true, "helper_target": true, "helper_target_unknown": true,
	"kconfig": true, "kconfig_loader": true, "kconfig_loader_unknown": true, "kconfig_type": true, "kconfig_unknown": true, "kstructsize": true, "kstructsize_unknown": true,
	"ksymvar": true, "ksymvar_unknown": true, "sleepable_type": true, "sleepable_type_unknown": true, "typed_ksym_loader": true, "typed_ksym_loader_unknown": true,
	"program_type": true, "helper": true, "helper_unknown": true, "attach": true, "attach_tcx_unknown": true, "retsig_unknown": true,
	"farg": true, "farg_unknown": true, "attach_func_unknown": true, "arg_nullable_unknown": true, "arg_nullable": true, "arg_nullable_mark_unknown": true,
	"kfield": true, "attach_unknown": true, "kfield_unknown": true, "btf_feature": true, "btf_feature_unknown": true, "btf_rewrite": true,
	"arg_tag": true, "arg_tag_unknown": true, "map_type": true, "arch": true, "arch_unknown": true, "ctxfield": true, "ctxfield_unknown": true,
	"attach_symbol_unknown": true, "attach_alias": true, "attach_alias_unknown": true, "kprobearg": true, "kprobearg_unknown": true,
	"map_field": true, "map_field_unknown": true,
	// E107 (bpf-mlir v1.10.0): kernel の能力 (program type の attach・ctx の field・kfunc・tracefs・置き換え先・struct_ops) と loader の宣言の問い
	"attach_target": true, "attach_target_unknown": true, "attach_type": true, "attach_type_unknown": true, "ctx_access": true, "ctx_access_unknown": true,
	"ext_target": true, "ext_target_unknown": true, "kfunc_allowed": true, "kfunc_allowed_unknown": true, "kfunc_sig": true, "kfunc_sig_unknown": true,
	"structop": true, "structop_unknown": true, "sysarg": true, "sysarg_unknown": true, "tpfield": true, "tpfield_unknown": true,
	"fsession_loader": true, "fsession_loader_unknown": true, "ksyscall_loader": true, "ksyscall_loader_unknown": true,
	"lsm_cgroup_loader": true, "lsm_cgroup_loader_unknown": true, "usdt_loader": true, "usdt_loader_unknown": true,
}

// uprobeBuildCaps は build の時の caps — uprobe の binary (宣言の path の file) だけを答える。
type uprobeBuildCaps struct{ files map[string]string }

func (uprobeBuildCaps) HasProgType(string, int64) (bool, error) { return false, nil }
func (uprobeBuildCaps) HasHelper(string, int64, string, int64) (bool, error) {
	return false, requirements.ErrUnknown
}
func (uprobeBuildCaps) HasMapType(string, int64) (bool, error) { return false, nil }
func (c uprobeBuildCaps) UprobeBinary(program string) (io.ReaderAt, error) {
	p, ok := c.files[program]
	if !ok {
		return nil, fmt.Errorf("no target file for %s", program)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	return bytes.NewReader(b), nil
}

// debugRoot は build の時の分けた DWARF の build ID の探索の root (E156 — bml の load の既定と同じ /usr/lib/debug、"" は探索しない)。
var debugRoot = "/usr/lib/debug"

// UprobeDebugFile は本体に DWARF の無い target (system の libc 等) の分けた DWARF — root/.build-id/xx/rest.debug (bpf-mlir E557)。
func (uprobeBuildCaps) UprobeDebugFile(_ string, buildID []byte) (io.ReaderAt, error) {
	root := debugRoot
	if mutation("uprobe-debug-off") { // 変異 (E156 H6): 分けた DWARF を探さない — libc の引数と戻り値の型が Unknown になる
		root = ""
	}
	p, err := requirements.BuildIDDebugPath(root, buildID)
	if err != nil {
		return nil, err
	}
	return requirements.ReadUprobeDebugFile(p)
}

// UprobeBuildCheck は ELF の uprobe の requirements を build の時の target の file で照合する (uprobe の program が無ければ何もしない)。
func UprobeBuildCheck(elf []byte, res *Result) error {
	files := map[string]string{}
	decl := map[string]Pos{}
	for _, p := range res.Programs {
		if p.Kind == "uprobe" || p.Kind == "uretprobe" { // P026 E112: uretprobe も target の file で (uretprobe_abi)
			files[p.Name], decl[p.Name] = p.BinaryPath, p.DeclPos
		}
	}
	return UprobeBuildCheckFiles(elf, files, decl)
}

// UprobeBuildCheckFiles は UprobeBuildCheck の照合の本体 — program の名前から target の file と宣言の位置 (P029 E152: seam は
// consumer の uprobe_targets から渡す)。
func UprobeBuildCheckFiles(elf []byte, files map[string]string, decl map[string]Pos) error {
	if len(files) == 0 {
		return nil
	}
	parsed, err := bindrt.Parse(elf)
	if err != nil {
		return fmt.Errorf("the build-time uprobe check could not read the ELF: %w", err)
	}
	us, err := parsed.CheckTarget(uprobeBuildCaps{files})
	if err != nil {
		return fmt.Errorf("the build-time uprobe check failed: %w", err)
	}
	// program ごとに 1 つの SB032 (1 つの原因 — 例えば無い symbol — が uprobe_symbol と引数ごとの uprobearg_unknown を重ねて出すので、行を 1 つの文に)
	lines := map[string][]string{}
	var order []string
	for _, u := range us {
		if UprobeBuildIgnored[u.Kind] {
			continue
		}
		if _, seen := lines[u.Program]; !seen {
			order = append(order, u.Program)
		}
		if UprobeBuildKinds[u.Kind] {
			lines[u.Program] = append(lines[u.Program], fmt.Sprintf("%s %s: %s", u.Kind, u.Name, u.Detail))
			continue
		}
		lines[u.Program] = append(lines[u.Program], fmt.Sprintf("%s %s: %s (an Unmet kind the build-time check does not classify — stopping, fail closed; classify it in UprobeBuildKinds or UprobeBuildIgnored)", u.Kind, u.Name, u.Detail))
	}
	var ds Diags
	for _, p := range order {
		ds = append(ds, Diag{Verdict: Rejected, Code: SB032UprobeTarget, Pos: decl[p],
			Msg: fmt.Sprintf("the uprobe target fails bpf-mlir's check before load: %s (the build checks the file it read; the load checks the running target again)", strings.Join(lines[p], "; "))})
	}
	if len(ds) > 0 {
		return &Error{Diags: ds}
	}
	return nil
}
