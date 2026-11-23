# E287: path_eq(file, "/literal/path") — Tetragon の matchBinaries 相当。
#
# AOT の利点をそのまま使う: リテラルの長さとバイト列がコンパイル時に既知なので、
# ちょうどのサイズの stack buffer + unroll したバイト比較に落ちる。Tetragon は
# ポリシーを再コンパイルできないので string map (7 サイズクラス) + LPM trie を
# 抱えるが、spinel-ebpf はリテラルをプログラムに焼ける。
#
# buffer をリテラル長ちょうどに切るのは制限ではなく正しい意味論 (E286 実測):
# 実パスがリテラルより長ければ bpf_d_path が -ENAMETOOLONG を返す => 不一致。
#
# path_eq は式なので `if` を駆動できる (emit_path (E286) は文)。
@denied = 0
@allowed = 0

def fmod_ret__security_file_open(file, ret)
  if path_eq(file, "/etc/spnl_e287_secret")
    @denied = @denied + 1
    -1
  else
    @allowed = @allowed + 1
    ret
  end
end
