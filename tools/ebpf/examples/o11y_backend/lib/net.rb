# 共有: socket / epoll / fork の FFI 宣言 (upstream sp_net + spinel-ebpf の rl_ shim)
#
# sp_net_rl_* (read_line バッファを drain してから読む binary-safe 変種、E187/E193) は
# spinel-ebpf 所有の shim TU (src/runtime/sp_net_ext.c)。bin/spinel-ebpf の extra_sources が
# 常にリンクするので、ingestd/queryd は bin/spinel-ebpf でビルドする (README 参照)。

module Net
  ffi_func :sp_net_listen,         [:int, :int], :int   # (port, reuseport) — 第 2 引数は backlog ではない
  ffi_func :sp_net_accept,         [:int],       :int   # TCP_NODELAY は upstream が自動設定
  ffi_func :sp_net_read_line,      [:int],       :str   # CRLF 除去済み。"" = 空行 or EOF
  ffi_func :sp_net_write_str,      [:int, :str], :int
  ffi_func :sp_net_rl_recv_some,   [:int, :int], :binstr
  ffi_func :sp_net_rl_close,       [:int],       :int
  ffi_func :sp_net_fork,           [],           :int
  ffi_func :sp_net_getpid,         [],           :int
  ffi_func :sp_net_epoll_create,   [],           :int
  ffi_func :sp_net_epoll_add,      [:int, :int], :int
  ffi_func :sp_net_epoll_del,      [:int, :int], :int
  ffi_func :sp_net_epoll_wait_one, [:int],       :int
end
