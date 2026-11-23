#!/bin/sh
# ライブコンパイルデモ: Ruby → C → ビルド を 3 ステップで見せる。
# 使い方:  sh examples/live_demo/compile_demo.sh [foo.rb]
#   引数なしなら ws_traffic.rb(kprobe で :8080 送信を観測する eBPF) を題材にする。
#   各ステップは Enter で進む(ライブで喋りながら見せる用)。
RB="${1:-examples/live_demo/ws_traffic.rb}"
OUT=/tmp/cdemo
cd /work || exit 1
base=$(basename "$RB" .rb)
rm -rf "$OUT"; mkdir -p "$OUT"
B=$(printf '\033[1m'); C=$(printf '\033[1;36m'); Y=$(printf '\033[33m')
G=$(printf '\033[32m'); D=$(printf '\033[2m'); R=$(printf '\033[0m')
rule="------------------------------------------------------------"
pause(){ printf "\n%s  [Enter for next]%s" "$D" "$R"; read _; }

printf "%s== spinel-ebpf: write Ruby → compile to C → build ==%s\n" "$C" "$R"

printf "\n%s① Ruby source%s  (%s)\n" "$B" "$R" "$RB"
printf "%s\n" "$rule"; cat "$RB"; printf "%s\n" "$rule"
pause

printf "\n%s② Compile Ruby → C%s  (no build yet: source generation only)\n" "$B" "$R"
printf "%s\$ spinel-ebpf compile %s -o %s%s\n\n" "$Y" "$RB" "$OUT" "$R"
ruby bin/spinel-ebpf compile "$RB" -o "$OUT" 2>&1 | grep -vE '\.ir$'
printf "\n  → two C files come out: %s%s.c%s(native, runs on the host) and %s%s.bpf.c%s(eBPF, runs in the kernel)\n" "$C" "$base" "$R" "$C" "$base" "$R"
pause

printf "\n%s   The generated eBPF C  (%s.bpf.c)%s\n" "$B" "$base" "$R"
printf "%s\n" "$rule"; cat "$OUT/$base.bpf.c"; printf "%s\n" "$rule"
printf "  ↑ the Ruby method in %s became the eBPF program %sSEC(\"kprobe/tcp_sendmsg\")%s\n" "$RB" "$C" "$R"
pause

printf "\n%s③ Build%s  (.bpf.c →[clang -target bpf]→ eBPF bytecode .bpf.o → skeleton → linked with native)\n" "$B" "$R"
printf "%s\$ spinel-ebpf compile %s --build -o %s%s\n\n" "$Y" "$RB" "$OUT" "$R"
ruby bin/spinel-ebpf compile "$RB" --build -o "$OUT" 2>&1 | grep -iE 'wrote|eBPF programs' | grep -vi warning
printf "\n  Products:\n"
ls -la "$OUT/$base" "$OUT/$base.bpf.o" 2>/dev/null | awk '{printf "   %9s  %s\n",$5,$NF}'
file "$OUT/$base" 2>/dev/null | sed 's/^/   /'
printf "\n  → running %s%s/%s%s loads and attaches the eBPF program.\n" "$G" "$OUT" "$base" "$R"
printf "  (type a larger command in the interactive terminal above, and the bytes sent stream below)\n"
