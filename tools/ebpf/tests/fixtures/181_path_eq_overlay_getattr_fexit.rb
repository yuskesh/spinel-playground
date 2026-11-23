# E420 negative fixture: the fourth SEC.
#
# fexit/vfs_getattr, so that all four hooks E418 measured (fentry|fexit x
# dentry_open|vfs_getattr) have a committed refusal, not just a representative.
@denied = 0

def fexit__vfs_getattr(path, stat, request_mask, query_flags, ret)
  if path_eq(path, "/etc/shadow")
    @denied = @denied + 1
  end
  0
end
