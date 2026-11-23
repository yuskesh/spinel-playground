# 共有: gzip inflate の FFI 面 (E452)。実体は native/o11y_gzip.c (zlib)。
#
#   out = GZ.o11y_gunzip(data, data.length)   # :binstr
#   GZ.o11y_gunzip_err != 0 なら失敗 (1=サイズ上限超過, 5=途中で切れている, 負=zlib コード)
#
# 空メッセージの gzip は正当 (out="" かつ err=0) なので、成否は必ず err で判定する。

module GZ
  ffi_lib "z"
  ffi_cflags "native/o11y_gzip.c"
  ffi_func :o11y_gunzip,     [:str, :int], :binstr
  ffi_func :o11y_gunzip_err, [],           :int
end
