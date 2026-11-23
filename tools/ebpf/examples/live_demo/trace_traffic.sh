#!/bin/sh
# ライブデモ: この端末を配信しているサーバの通信を eBPF で可視化する。
# Ruby で書いた可視化プログラムを「その場でコンパイル → ビルド → 実行」まで見せる。
cd /work
echo "# An eBPF visualization program written in Ruby:"
echo "------------------------------------------------------------"
cat examples/live_demo/ws_traffic.rb
echo "------------------------------------------------------------"
echo ""
echo "\$ ruby bin/spinel-ebpf compile examples/live_demo/ws_traffic.rb -o /tmp/wstraf --build"
ruby bin/spinel-ebpf compile examples/live_demo/ws_traffic.rb -o /tmp/wstraf --build 2>/dev/null
echo ""
echo "\$ /tmp/wstraf/ws_traffic        # run it → type in the terminal above and the bytes sent stream by"
echo ""
exec /tmp/wstraf/ws_traffic
