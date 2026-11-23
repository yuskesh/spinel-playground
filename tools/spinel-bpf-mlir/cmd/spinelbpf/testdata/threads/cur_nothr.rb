# E048 H3: Thread の定数を書かずに今の green thread を C から知る口 (sp_Thread_current — weak)。Thread 無しの program。
module Cur
  ffi_source <<~C
    long cur_thread(void) { return (long)sp_Thread_current(); } /* spinel_rt.h (sp_sched.h:142) が宣言 — 両方の runtime の archive に定義 */
  C
  ffi_func :cur_thread, [], :long
end
puts "main=#{Cur.cur_thread} again=#{Cur.cur_thread}"
