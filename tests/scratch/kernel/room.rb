# Decision 0041 stage 2: exactly the room of a 256-byte region on a 64-bit
# host, 31 elements (248 bytes), is static_proof; room32.rb, one more, is
# refused with scratch-capacity.
def tick(out)
  a = Core::Buffer.i64(31, 1)
  out[0] = a[30]
  0
end
