# E390: exec を撃つ hook でパスを見る (`struct linux_binprm *` 形)。
#
# lsm/bprm_check_security の引数は binprm なので、パスは 2 ホップ先
# (`bprm->file->f_path`)。**直接 deref** で辿るのが肝 — BPF_CORE_READ はスカラを返し、
# trusted ポインタを要求する bpf_d_path に渡せない (E288)。
# NULL guard は fail-safe (パス不明 = 不一致、E287 と同方針)。
#
# 「この実行ファイルの exec を deny」+ 「何が exec されたかを記録」。
@denied = 0

def lsm__bprm_check_security(bprm)
  emit_path(bprm)
  if path_eq(bprm, "/usr/bin/spnl_e390_bad")
    @denied = @denied + 1
    -1
  else
    0
  end
end
