# E109 demo: raw tracepoint counting every syscall entry. Auto-attached.
@syscalls = 0
def raw_tp__sys_enter
  @syscalls = @syscalls + 1
end
puts "[E109] raw_tp/sys_enter counting syscalls"
sleep 3600
