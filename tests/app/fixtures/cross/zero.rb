# tests/app/fixtures/cross/zero.rb -- an entry that needs no stack frame.
#
# On thumbv8m a checked `a + b` already pushes two registers (8 bytes), so the
# zero-frame entry of the 0010 method is the identity: `mov r0, r2; mov r1,
# r3; bx lr` and nothing saved. cross.sh requires the method to read it as
# zero, not as an absent measurement.

def z_id(a)
  a
end
