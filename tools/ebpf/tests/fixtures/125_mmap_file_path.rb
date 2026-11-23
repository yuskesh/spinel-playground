# E390: lsm/mmap_file — 実行可能マッピングの元ファイルをパスで見る。
#
# この hook の引数は BTF 上 `file__nullable` (匿名 mmap は file == NULL)。
# NULL guard は防御ではなく **load 必須**: 無 guard 版は verifier に
# "R1 pointer arithmetic on trusted_ptr_or_null_ prohibited, null-check it first"
# で拒否される (E390 c12 vs c10 の直接対照)。guard 版は「パス不明 = 不一致」に倒れる。
@denied = 0

def lsm__mmap_file(file, reqprot, prot, flags)
  emit_path(file)
  if path_starts_with(file, "/tmp/")
    @denied = @denied + 1
    -1
  else
    0
  end
end
