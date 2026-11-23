# E048 H3: 同じ口を Thread 有りの program で (main と 4 つの Thread — 各 Thread の中で 2 回)。
module Cur
  ffi_source <<~C
    long cur_thread(void) { return (long)sp_Thread_current(); } /* spinel_rt.h (sp_sched.h:142) が宣言 — 両方の runtime の archive に定義 */
  C
  ffi_func :cur_thread, [], :long
end
puts "main=#{Cur.cur_thread} again=#{Cur.cur_thread}"
ts = []
4.times do |i|
  ts << Thread.new do
    a = Cur.cur_thread
    Thread.pass
    b = Cur.cur_thread
    "t#{i} first=#{a} second=#{b}"
  end
end
ts.each { |t| puts t.value }
puts "main after=#{Cur.cur_thread}"
