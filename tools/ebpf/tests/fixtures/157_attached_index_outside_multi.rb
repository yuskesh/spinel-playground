# E401 (P011 S12): 1 対 1 の handler で attached_index を呼ぶ。
# そこでは attach 先はメソッド名なので「訊く」対象が無い — 定数 0 を返さず落とす。
def kprobe__vfs_read
  @n = @n + attached_index
  0
end
