# 共有: h2c + gRPC unary 受信の FFI 面 (E451)
#
# 実体は native/o11y_h2.c (nghttp2 の callback/HPACK/flow control を C 側に閉じ込め、
# Ruby には「完成リクエストの取り出し / 応答」だけを見せる — E445 追記の作法)。
# 使い方は ingestd.rb の serve_h2 を参照。

module H2
  ffi_lib "nghttp2"
  ffi_cflags "native/o11y_h2.c"
  ffi_func :h2_open,         [:int], :int
  ffi_func :h2_is_open,      [:int], :int
  ffi_func :h2_feed,         [:int], :int          # <0 = 接続終了 (epoll から外して h2_close)
  ffi_func :h2_next_stream,  [:int], :int          # 完成リクエスト queue 先頭の stream id | -1
  ffi_func :h2_req_path,     [:int], :str
  ffi_func :h2_req_encoding, [:int], :str   # grpc-encoding ヘッダ ("" = 無し)
  ffi_func :h2_req_body,     [:int], :binstr       # gRPC 5-byte prefix 込みの生 body
  ffi_func :h2_req_pop,      [:int], :void
  ffi_func :h2_respond_grpc, [:int, :int, :int, :str], :int
  ffi_func :h2_close,        [:int], :void
end

# gRPC status (trailer grpc-status に載せる値)
GRPC_OK               = 0
GRPC_INVALID_ARGUMENT = 3
GRPC_INTERNAL         = 13
GRPC_UNIMPLEMENTED    = 12
