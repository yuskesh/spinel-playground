# E390: パス基準ポリシーを **open 以外の security hook** に。
#
# ここまで path 系 builtin (emit_path / path_eq / ...) は bpf_d_path の kernel gate
# のせいで 3 hook (file_open 系) にしか書けなかった。E390 が 7.1.5-ebpf で全マス実測し、
# security_path_* family が LOAD_OK であることを確認したので gate に入った
# (ADR-003: 実測した hook だけ)。
#
# lsm/path_unlink の第 1 引数は **既に `struct path *`** なので、file 系の
# `&file->f_path` 変換は要らない (hook ごとに供給形が違う = E390 の codegen 側の肝)。
# 「特定パス配下の削除を deny」が Ruby 数行。
@denied = 0
@allowed = 0

def lsm__path_unlink(dir, dentry)
  if path_eq(dir, "/etc/spnl_e390")
    @denied = @denied + 1
    -1
  else
    @allowed = @allowed + 1
    0
  end
end
