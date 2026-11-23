module Native
  ffi_func :add_one, [:int], :int
end

puts Native.add_one(41)
