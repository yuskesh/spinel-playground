# ライブデモ: この端末を配信しているサーバ(:8080)が「ブラウザへ押し出すバイト数」を
# eBPF で可視化する。= あなたが上の端末で打つ ls / cat / vi の出力が、サーバ→ブラウザへ
# WS フレームとして流れる瞬間を、カーネル内の kprobe が捉える。
#
# フィルタは 2 段:
#   port == 8080  … このデッキ配信サーバの socket だけに絞る(他の通信ノイズを除外)
#   size  > 256   … 「意味のある」送信だけ(プロンプト echo や WS ヘッダ等の小さな送信は捨てる)
#
# この size>256 が自己フィードバックも断つ: このトレーサ自身の出力行(各 ~25B)は
# 256 未満なので観測対象に入らない。よって下の端末でこれを走らせても暴走しない。
#
# ※ port==8080(kfield で sk->__sk_common.skc_num を CO-RE 読取)も size>256 の比較も、
#    どちらも「if … end(else 無し)」で戻り値が int? に widening される。本体の推論系が
#    int? を eBPF 非対象と誤判定していたのを修正した(E185)ことで、この素直な書き方が
#    そのまま eBPF にコンパイルされる。
module Stream
  ffi_func :spnl_stream, [:int], :int
end

def kprobe__tcp_sendmsg(sk, msg, size)
  port = kfield(sk, "sock", "__sk_common.skc_num")
  if port == 8080 && size > 256
    spnl_emit(size)            # サーバ(:8080)→ブラウザへ押し出したバイト数
  end
end

puts "[ws-traffic] eBPF: :8080 server -> browser bytes sent (>256B only), streaming:"
Stream.spnl_stream(0)
