# E457/E458: the STATIC shim binding — the plain-C surface of
# native/gpu_metal_shim.m, owned by the shim (it changes only when the shim's
# API does). Everything KERNEL-derived (init arity, slot accessors, dispatch
# names) lives in the generated <base>_host.rb instead, extracted from the
# .metal the gpu-metal codegen emits — require this file first, then that one.

module GPU
  ffi_cflags "native/gpu_metal_shim.m"
  ffi_cflags "-framework Metal -framework Foundation"
  ffi_func :ogpu_init,     [:str, :str, :long], :int    # (metal_path, type spec "f"/"l" per slot, n)
  ffi_func :ogpu_write,    [:long, :long, :double], :void
  ffi_func :ogpu_read,     [:long, :long], :double
  ffi_func :ogpu_write_i,  [:long, :long, :long], :void  # E459: int64 lane (2^53-safe)
  ffi_func :ogpu_read_i,   [:long, :long], :long
  ffi_func :ogpu_dispatch, [:str, :long], :int
end
