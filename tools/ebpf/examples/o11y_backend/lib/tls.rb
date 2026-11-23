# 共有: TLS 終端の FFI 面 (E453)。実体は native/o11y_tls.c (mbedTLS、ADR-013 の vendored 品)。
#
# ポートごとに ALPN 固定の config を選ぶ:
#   TLS.otls_accept(fd, 0)  … OTLP/HTTPS (ALPN http/1.1)
#   TLS.otls_accept(fd, 1)  … OTLP/grpcs (ALPN h2)
# h2-over-TLS の I/O 切替は o11y_h2.c 側が otls_is(fd) で行う (Ruby からは不可視)。
# HTTP/1.1 側は sp_net rl_* と同じ意味論の otls_read_line / otls_recv_some を使う。

module TLS
  ffi_cflags "-I../../third_party/mbedtls/include"
  ffi_cflags "-L../../third_party/mbedtls/library"
  ffi_cflags "native/o11y_tls.c"
  ffi_lib "mbedtls"
  ffi_lib "mbedx509"
  ffi_lib "mbedcrypto"
  ffi_func :otls_init,        [:str, :str], :int   # (cert_path, key_path)。-2/-3 = cert/key parse 失敗
  ffi_func :otls_accept,      [:int, :int], :int   # (fd, mode 0=http/1.1 1=h2)。-2 = handshake 失敗
  ffi_func :otls_alpn,        [:int], :str
  ffi_func :otls_is,          [:int], :int
  ffi_func :otls_read_line,   [:int], :str
  ffi_func :otls_recv_some,   [:int, :int], :binstr
  ffi_func :otls_write_bytes, [:int, :str, :int], :int
  ffi_func :otls_close,       [:int], :void
end
