# spinel/tensor.rb -- the user-facing tensor surface (E031, R004 design A).
#
# Shipped as a source library and pulled in with
#
#     require_relative "spinel/tensor"
#
# which spinel resolves at COMPILE time (textual insertion, src/spinel_parse.c
# resolve_requires), so the declarations below are visible both to the compiler
# and to `spinel-mlirgen --tensor`, which reads them back out of `--dump-ast`.
# R004 probe P13.
#
# Two worlds, exactly as Nx splits `defn` from ordinary Elixir (R004 s1.1):
#
#   * KERNEL WORLD -- a `tensor_def` declaration plus the `def` it marks.  The
#     body is a *declaration*, not executable Ruby: `spinel-mlirgen --tensor`
#     reads it, compiles it to one `linalg.generic`, and emits a dispatching
#     `def` of the same name into <kernels>.gen.rb.  The operators below exist
#     so the kernel file parses and type-checks; every one of them raises if it
#     is ever actually called (E018/E012 policy: never silently do the wrong
#     thing).  A kernel file is NEVER required into a program -- the generated
#     .gen.rb is.  (E031 s2: spinel rejects a duplicate top-level `def`, so the
#     generated dispatch cannot overwrite the declaration in place.)
#
#   * HOST WORLD -- everything else.  `Tensor` owns its buffer; `@data` does not
#     exist at all, only an opaque device handle.  This is R004 s2.3's central
#     finding made structural: a raw `Array[Float]` that widens to poly loses
#     destination-passing writes silently (P14) and `:float_array` will happily
#     eat a nested array and return garbage (P12).  Neither hazard has a
#     syntactic route in here.
#
# The precision contract is in the name of the readback: `.to_f32_a`.  There is
# deliberately no `.to_a`.  Values that come back went f64 -> f32 -> f64 and are
# NOT the f64 answer (E030 s3: normwise 3.41e-08, 35.6% of elements differ at
# N=4M).  See docs/experiments/E030_spinel_gpu_bridge.md.

# --------------------------------------------------------------------------
# The C seam.  tools/tensor/sp_tensor_shim.c implements all of it on top of the
# IREE runtime C API; docs/tools/iree.md has the link recipe.  Everything here
# is scalar+pointer, which is the whole of Spinel's FFI boundary (R001 s1.5).
# --------------------------------------------------------------------------
module SPT
  # session.  `sp_t_open` takes a .vmfb path, or "@name" for a module the
  # program's own C TU registered at start-up (E037 s2: iree-c-embed-data output
  # linked INTO the binary, so there is no second file to ship).
  ffi_func :sp_t_open,       [:str, :str],                                     :int
  # E037 s3: a SECOND module in the SAME session.  IREE's session takes any
  # number of bytecode modules; until E037 the surface only ever appended one,
  # which is why E034's preprocessing had to stay in the Ruby `while` loop.
  ffi_func :sp_t_append,     [:str],                                           :int
  ffi_func :sp_t_close,      [],                                               :void
  ffi_func :sp_t_last_error, [],                                               :str

  # device-resident buffers (residency is the precondition, not a nicety --
  # E030 s4.2: without it the GPU never wins).  `sp_t_alloc(d0, d1)`: d1 == 0
  # means rank 1 (a :vec of d0 elements), otherwise rank 2 (a :mat, d0 x d1).
  # The rank travels with the buffer so the shim can check a kernel's declared
  # ranks and shape constraints before it pushes a single argument (E033 s4).
  ffi_func :sp_t_alloc,      [:size_t, :size_t],                               :int64
  # E037: the same allocation with an ELEMENT TYPE.  0 f32, 1 u8, 2 f16, 3 i8,
  # 4 i32 -- the codes are sp_tensor_shim.c's SP_T_* enum and the digits in the
  # `dtypes` column of the generated entry table.  `sp_t_alloc` is exactly
  # `sp_t_alloc_dt(d0, d1, 0)`, so every E031..E036 program is unchanged.
  ffi_func :sp_t_alloc_dt,   [:size_t, :size_t, :int],                         :int64
  # E039: the general form.  Through E038 the rank was ENCODED in the arity
  # (d1 == 0 meant rank 1), which cannot say "a rank-3 image whose channel axis
  # is 1".  Here the rank is an argument.  Fixed six arguments rather than a
  # dimension array because Spinel's FFI has no way to hand C an int array of a
  # length the callee reads (R005 s2.4-C), and because keeping sp_t_alloc_dt
  # makes the ABI compatibility of every E031..E038 dispatch explicit rather
  # than incidental.
  ffi_func :sp_t_alloc_nd,
           [:size_t, :size_t, :size_t, :size_t, :int, :int],                    :int64
  ffi_func :sp_t_free,       [:int64],                                         :void
  ffi_func :sp_t_fill,       [:int64, :double, :size_t],                       :int
  ffi_func :sp_t_h2d,        [:int64, :float_array, :size_t],                  :int
  # E037 s3: raw bytes into a :u8/:i8 tensor.  A String read off a file already
  # IS the bytes the device wants, so this is a memcpy and the Ruby side does no
  # per-element work at all -- which is the whole of E034 s7's 39 ms.
  ffi_func :sp_t_h2d_bytes,  [:int64, :str, :size_t],                          :int
  ffi_func :sp_t_d2h,        [:int64, :float_array, :size_t],                  :int
  # E072 s1 (P002 Phase 4): raw bytes OUT of a :u8/:i8 tensor.  The mirror of
  # sp_t_h2d_bytes, and the thing E069 s7.3 named as Phase 4's largest single
  # dividend: at 4K the Metal pipeline computed its answer in 3.94 ms and then
  # spent 24.94 ms in `to_f_a`, which builds an 8 294 400-element Ruby Array of
  # Floats for a result that IS 8 294 400 bytes.
  #
  # `:binstr` and not `:str`: the String is built from the exact byte count the
  # callee publishes in `sp_ffi_bin_len` (vendor/spinel docs/FFI.md), so a black
  # pixel (0x00) does not truncate the image.  The C side returns a BORROWED
  # pointer into its staging buffer, and the `:binstr` lowering copies it into a
  # GC String inside the same expression -- which is why `#to_bytes` hands the
  # result straight back and nothing ever holds the pointer.
  ffi_func :sp_t_d2h_bytes,  [:int64, :size_t],                                :binstr

  # kernel dispatch: one generic entry point over the N-entry table the
  # generator emits (sp_tensor_table.h).  Unused tensor slots are passed as 0.
  # The second argument is the SIGNATURE HASH of the declaration the calling
  # dispatch was generated from; the shim refuses to run an entry whose table
  # row disagrees (E033 s4 -- a stale .gen.rb cannot silently call a kernel
  # with a different argument order).
  ffi_func :sp_t_invoke,
           [:str, :int64, :double, :int64, :int64, :int64, :int64, :size_t],   :int
  ffi_func :sp_t_invoke_f,
           [:str, :int64, :double, :int64, :int64, :int64, :int64, :size_t],   :double
  # E038 (R004 stage 3, design B): the dispatch a FUSED call-site expression is
  # rewritten into.  The only difference from sp_t_invoke is that it carries up
  # to four captured scalars instead of one: `y.assign!(x * a + y * b)` mentions
  # two Ruby numbers, and they are passed at RUN TIME, never folded into the
  # .vmfb (a folded literal would make every distinct constant its own kernel
  # and would simply not work when the number is a variable).
  ffi_func :sp_t_invoke_fx,
           [:str, :int64, :double, :double, :double, :double,
            :int64, :int64, :int64, :int64, :size_t],                          :int

  # transfer counters, for the residency gate (E031 gate d)
  #   0 h2d  1 d2h  2 invoke  3 alloc  4 free  5 fill
  ffi_func :sp_t_counter,    [:int],                                           :int64
end

# --------------------------------------------------------------------------
# The declaration DSL.  A no-op at run time; the generator reads it from the
# AST.  R004 s2.2: a top-level `def` used as a class/top-level macro really does
# run, so a declaration whose meaning depended on execution would carry two
# meanings at once.  This one has exactly one.
#
#   tensor_def :saxpy, dtype: :f32, params: [:scalar, :vec, :vec], dest: 2
#   tensor_def :sumsq, dtype: :f32, params: [:vec], returns: :scalar
#   tensor_def :sumsq_ft, dtype: :f32, params: [:vec], returns: :scalar,
#              reduction: :fixed_tree
#
# `reduction:` is the summation-order contract (R004 decision record):
#   :default    (omitted) -- backend-defined order.  Verified normwise against
#                an f64 oracle with an N-scaled bound; NOT bitwise across
#                devices, and E031 s6 measured how far that can go (2e-02 at
#                N=16.7M on the CPU path).
#   :fixed_tree -- a device-independent fixed-arity tree.  Bitwise identical on
#                every backend, at the cost of extra dispatches.
# The mode is an attribute of the DECLARATION and can never be a run-time
# argument: the .vmfb is built at compile time and the binary carries no
# compiler (E030).
# --------------------------------------------------------------------------
def tensor_def(name, dtype: :none, params: [], dest: -1, returns: :none,
               reduction: :default)
  0
end

# --------------------------------------------------------------------------
# E034: the FOREIGN-MODULE declaration.
#
# `tensor_def` describes a kernel whose MLIR spinel-mlirgen writes itself.
# `tensor_extern` describes an entry in a `.vmfb` that came from somewhere
# else -- in E034, a StableHLO module exported by JAX from a model trained in
# Python.  The generator writes no MLIR for it: it writes the same two things
# it writes for a tensor_def (a row in the shim's entry table and a dispatching
# `def` in the .gen.rb) and nothing more.
#
#   tensor_extern :mnist_mlp, dtype: :f32,
#                 vm_module: :jit_infer, entry: :main,
#                 params: [:mat], shapes: [[:b, 784]],
#                 returns: :mat, returns_shape: [:b, 10]
#
#   * `vm_module:`/`entry:` name the function inside the foreign .vmfb.  A
#     module spinel-mlirgen generated is always `module.<name>`; a foreign one
#     brings its own namespace (jax.export names the module after the jitted
#     function), so it has to be said out loud.
#   * `shapes:`/`returns_shape:` are a TRANSCRIPTION of the foreign signature.
#     An Integer is a fixed dimension; a Symbol is a dimension variable, and
#     every position that spells the same Symbol must agree at run time.  The
#     generator turns this into the same shape constraints a tensor_def body
#     implies, so a wrong-width batch is refused by name before a single
#     argument is pushed.
#   * `returns:` is why this is not just a tensor_def with a foreign name.  A
#     generated kernel is DESTINATION-PASSING -- every tensor is an argument and
#     the result is adopted back into the destination.  An exported model is
#     usually not: `main(x) -> y` takes one argument and returns its result.
#     The generated dispatch is still `mnist_mlp(x, logits)` -- the trailing
#     Tensor is where the returned buffer view is adopted -- but only the
#     arguments are pushed.
#
# A transcription can lie, which is why `spinel-mlirgen --extern-check <.mlir>`
# reads the exported StableHLO back and refuses to emit a table whose
# declaration disagrees with the module's own func.func signature.
# --------------------------------------------------------------------------
#   * E037 s6: `dtypes:` and `returns_dtype:` are OPTIONAL overrides of
#     `dtype:`, one per tensor, for a signature that is MIXED -- the E037
#     preprocessing export takes ui8 pixels and returns f32.  The element types
#     the shim can hold are :f32 :u8 :f16 :i8 :i32; --extern-check reads the
#     module's own element types and refuses both a wrong transcription and a
#     module using a type that is not on that list.
#
#   tensor_extern :mnist_u8, dtype: :f32,
#                 vm_module: :jit_infer_u8, entry: :main,
#                 params: [:mat], dtypes: [:u8], shapes: [[:b, 784]],
#                 returns: :mat, returns_shape: [:b, 10]
def tensor_extern(name, dtype: :none, vm_module: :module, entry: :none,
                  params: [], shapes: [], returns: :none, returns_shape: [],
                  dtypes: [], returns_dtype: :none)
  0
end

class TensorError < StandardError
end

class Tensor
  # ---- residency scope (R004 s3.1, P10's block form) ---------------------
  # Every Tensor must be constructed, used and read back inside one of these.
  # Leaving the block tears the device session down; handles do not survive it.
  def self.device(device_uri, vmfb_path)
    rc = SPT.sp_t_open(vmfb_path, device_uri)
    if rc != 0
      raise TensorError, "Tensor.device(#{device_uri}): #{SPT.sp_t_last_error}"
    end
    r = yield
    SPT.sp_t_close
    r
  end

  # E037 s3: load ANOTHER module into the open scope.  E034 s7 measured what
  # having only one costs: the model does the matmuls, and everything it does
  # not do (the u8 -> f32 scaling of 10 000 images) stays in a Ruby `while`
  # loop, where it took 39 ms -- more than the inference.  A second module is
  # the direct answer to that: the preprocessing becomes a dispatch like any
  # other kernel, and the Ruby side hands over bytes.
  #
  # `path` is a .vmfb path or "@name" for an embedded one (E037 s2).  The
  # modules must not collide in the VM namespace; ours do not, because the
  # namespace comes from the exporting tool (jax.export names the module after
  # the jitted function) and `tensor_extern` states it explicitly.
  def self.append(path)
    rc = SPT.sp_t_append(path)
    if rc != 0
      raise TensorError, "Tensor.append(#{path}): #{SPT.sp_t_last_error}"
    end
    0
  end

  # ---- construction: shape and dtype are DECLARED, never inferred --------
  # R004 s1.7-1: every surviving design in the field declares both.  Spinel's
  # inference has neither f32 nor shape (R001 s1.3), so this is the only route.
  def self.vec(dtype, n)
    Tensor.new(dtype, n, 0, 0, 0, 1)
  end

  # rank 2.  R004 s2.4 / probe P11: rank > 1 cannot live in the DATA (a nested
  # Ruby Array infers to sp_PolyArray*, which is boxed and not a double*), so
  # the rows/cols live in the declaration and the elements stay flat, row-major.
  def self.mat(dtype, rows, cols)
    Tensor.new(dtype, rows, cols, 0, 0, 2)
  end

  # E039 (P002 Phase 1).  rank 3 and rank 4, spelled as the plain continuation
  # of `vec` / `mat` rather than as `img` / `nhwc`.
  #
  # R004's line has been that this is a NUMERICAL surface and image processing
  # is an application of it (R005 s2.4-B), so the constructor may not be named
  # after the application: an `(H, W, C)` image and an `(x, y, z)` field are the
  # same rank-3 tensor to everything below this method.  What IS image-specific
  # -- that the last axis is the channel and that the layout is interleaved --
  # is a fact about the DATA the caller uploads, not about the surface, and the
  # only place the surface commits to it is the shape constraint the generator
  # derives (dimension by dimension, R005 s2.4-H).
  #
  # `Tensor.nd(:u8, [h, w, c])` was the other candidate and was NOT chosen: the
  # construction-site scan the fused route depends on
  # (spinel-mlirgen collect_tensor_ctors) reads the constructor's ARGUMENTS
  # syntactically, and an Array literal there would have to be read as a shape
  # -- a second syntactic form to support for no gain, since the rank is already
  # in the method name.
  def self.ten3(dtype, d0, d1, d2)
    Tensor.new(dtype, d0, d1, d2, 0, 3)
  end

  def self.ten4(dtype, d0, d1, d2, d3)
    Tensor.new(dtype, d0, d1, d2, d3, 4)
  end

  # from a flat Array[Float]; rank>1 data cannot live in the data (R004 s2.4 /
  # probe P11), so the shape is always declared here and the array is flat.
  def self.of(dtype, n, flat)
    if flat.length != n
      raise TensorError, "Tensor.of: declared shape [#{n}] but got #{flat.length} elements"
    end
    t = Tensor.new(dtype, n, 0, 0, 0, 1)
    t.store(flat)
    t
  end

  # rank-2 construction from a FLAT row-major Array[Float].  A nested Array is
  # not accepted anywhere in this surface (see the header).
  def self.of_mat(dtype, rows, cols, flat)
    if flat.length != rows * cols
      raise TensorError, "Tensor.of_mat: declared shape [#{rows}, #{cols}] = " \
                         "#{rows * cols} elements but got #{flat.length}"
    end
    t = Tensor.new(dtype, rows, cols, 0, 0, 2)
    t.store(flat)
    t
  end

  # E037: the element-type code the shim allocates with.  Through E036 a Tensor
  # was always f32, because every kernel was one spinel-mlirgen wrote and it
  # writes f32.  A FOREIGN module has its own types, so the surface grew exactly
  # the ones the shim can hold -- and no more: an unknown dtype still raises
  # here, before any allocation, and the generated table's `dtypes` column
  # re-checks the same thing at dispatch (E037 s6).
  #
  # There is deliberately no :f64.  The M1 GPU has none (E030 s3).
  def self.dtype_code(dtype)
    return 0 if dtype == :f32
    return 1 if dtype == :u8
    return 2 if dtype == :f16
    return 3 if dtype == :i8
    return 4 if dtype == :i32
    -1
  end

  # E039: the rank is now an EXPLICIT argument rather than `d1 == 0`.  Every
  # constructor above passes it, and for rank 1 and 2 the allocation still goes
  # through `sp_t_alloc_dt` -- the same C entry point, with the same two
  # dimensions, that E031..E038 measured -- so nothing about an existing program
  # changes shape here.
  def initialize(dtype, d0, d1, d2, d3, rank)
    dt = Tensor.dtype_code(dtype)
    if dt < 0
      raise TensorError, "Tensor: dtype #{dtype.inspect} is not supported " \
                         "(:f32, :u8, :f16, :i8, :i32; there is no :f64 -- " \
                         "the M1 GPU has none, E030 s3)"
    end
    if rank < 1 || rank > 4
      raise TensorError, "Tensor: rank #{rank} is outside 1..4 (:vec, :mat, :ten3, :ten4)"
    end
    if d0 < 0 || d1 < 0 || d2 < 0 || d3 < 0
      raise TensorError, "Tensor: negative dimension [#{d0}, #{d1}, #{d2}, #{d3}]"
    end
    @dt = dt
    @rank = rank
    @d0 = d0
    @d1 = d1
    @d2 = d2
    @d3 = d3
    n = d0
    n = n * d1 if rank >= 2
    n = n * d2 if rank >= 3
    n = n * d3 if rank >= 4
    @n = n
    if rank <= 2
      @h = SPT.sp_t_alloc_dt(d0, d1, dt)
    else
      @h = SPT.sp_t_alloc_nd(d0, d1, d2, d3, rank, dt)
    end
    if @h == 0
      raise TensorError, "Tensor.alloc(#{d0}, #{d1}, #{d2}, #{d3}, rank #{rank}): " \
                         "#{SPT.sp_t_last_error}"
    end
  end

  # The element-type code this Tensor was allocated with (0 f32, 1 u8, 2 f16,
  # 3 i8, 4 i32).  The shim compares it with the entry table's declared one.
  def dtype_code
    @dt
  end

  # The opaque device handle.  This is NOT the buffer: there is no way to get
  # an aliasing Ruby Array out of a Tensor, which is what closes P14/P12.
  def handle
    @h
  end

  # The number of ELEMENTS (rows * cols for a rank-2 tensor).
  def length
    @n
  end

  def rank
    @rank
  end

  def rows
    @d0
  end

  def cols
    @d1
  end

  # E039: the remaining axes of a :ten3 / :ten4.  Named `dim2` / `dim3` and not
  # `channels` / `depth` for the same reason `ten3` is not `img` -- the surface
  # does not know what the axes mean.
  def dim2
    @d2
  end

  def dim3
    @d3
  end

  def fill(v)
    check_live
    SPT.sp_t_fill(@h, v, @n)
    self
  end

  # host -> device.  Copies; the Array is not retained (docs/FFI.md: the FFI
  # lifetime contract is call-duration only).
  def store(flat)
    check_live
    if flat.length != @n
      raise TensorError, "Tensor#store: tensor is [#{@n}] but got #{flat.length} elements"
    end
    rc = SPT.sp_t_h2d(@h, flat, @n)
    if rc != 0
      raise TensorError, "Tensor#store: #{SPT.sp_t_last_error}"
    end
    self
  end

  # E037 s3: host -> device for a :u8/:i8 tensor, straight from a String.
  #
  # This is the one place the surface admits that a byte is already a value.
  # E034 s7's 39 ms was `read + unpack("C*") + a while loop that multiplied every
  # pixel by 1/255` -- and every part of that existed only because the sole route
  # into a Tensor was an Array of Ruby Floats.  With a :u8 tensor the bytes go in
  # as they came off the file and the scaling happens in the MODEL, where it is
  # one more fused elementwise op.
  def store_bytes(str)
    check_live
    if @dt != 1 && @dt != 3
      raise TensorError, "Tensor#store_bytes: this tensor is not :u8 or :i8, and raw " \
                         "bytes are only the representation of a byte tensor. Use " \
                         "#store, which converts Floats to the element type"
    end
    if str.length != @n
      raise TensorError, "Tensor#store_bytes: tensor is [#{@n}] but got #{str.length} bytes"
    end
    rc = SPT.sp_t_h2d_bytes(@h, str, @n)
    if rc != 0
      raise TensorError, "Tensor#store_bytes: #{SPT.sp_t_last_error}"
    end
    self
  end

  # THE readback, and the only device->host sync point.  Named for what it
  # returns: the f32 values the device computed, widened to Ruby Floats.  There
  # is no `.to_a` on purpose -- see the header.
  def to_f32_a
    check_live
    if @dt != 0
      raise TensorError, "Tensor#to_f32_a: this tensor is not :f32, and the name of " \
                         "this readback is its precision contract. Use #to_f_a, which " \
                         "says only that the values are widened to Ruby Floats"
    end
    out = Array.new(@n, 0.0)
    rc = SPT.sp_t_d2h(@h, out, @n)
    if rc != 0
      raise TensorError, "Tensor#to_f32_a: #{SPT.sp_t_last_error}"
    end
    out
  end

  # E037: the readback for the element types that are not f32.  Deliberately NOT
  # called `.to_a` either: the values are the device's, widened to Ruby Floats,
  # and for :f16 in particular they went f64 -> f16 -> f64 and are not the f64
  # answer.  The header's rule is unchanged -- the name says what came back.
  def to_f_a
    check_live
    out = Array.new(@n, 0.0)
    rc = SPT.sp_t_d2h(@h, out, @n)
    if rc != 0
      raise TensorError, "Tensor#to_f_a: #{SPT.sp_t_last_error}"
    end
    out
  end

  # E072 s1 (P002 Phase 4): device -> host for a :u8/:i8 tensor, straight into a
  # String.  The exact mirror of `#store_bytes`, and the reason it exists is a
  # measurement rather than a symmetry: E069 s7.3 measured the Metal 4K pipeline
  # computing in 3.94 ms and reading back in 24.94 ms, and the readback is
  # `to_f_a` -- 8.3 MB of device memory turned into an 8 294 400-element Ruby
  # Array of Floats, only to be rounded back to bytes and written to a file.
  #
  # This is the one place the surface admits that a byte is already a value, in
  # the outbound direction.  E037 s3 admitted it inbound (`store_bytes`), and
  # E069's handoff 1 is the observation that the two halves were not symmetric.
  #
  # The precision contract in the name still holds (see the header): `to_bytes`
  # says the values ARE bytes -- it refuses an f32 tensor by name rather than
  # quantising behind the caller's back, because where the rounding happens is a
  # declared semantic (E039 D5, `quant:`) and this method has no way to say it.
  def to_bytes
    check_live
    if @dt != 1 && @dt != 3
      raise TensorError, "Tensor#to_bytes: this tensor is not :u8 or :i8, and raw " \
                         "bytes are only the representation of a byte tensor. Use " \
                         "#to_f_a, which widens the elements to Ruby Floats -- or " \
                         "quantise on the device (a :u8 destination and `quant:`), " \
                         "which is where the rounding contract can be stated"
    end
    s = SPT.sp_t_d2h_bytes(@h, @n)
    # The FFI returns "" on every failure and the shim holds the reason.  A
    # short String is therefore never silently accepted -- which matters more
    # here than elsewhere, because the caller is about to write it to a file.
    if s.bytesize != @n
      raise TensorError, "Tensor#to_bytes: #{SPT.sp_t_last_error}"
    end
    s
  end

  def free!
    if @h != 0
      SPT.sp_t_free(@h)
      @h = 0
    end
    nil
  end

  def check_live
    if @h == 0
      raise TensorError, "Tensor: use after free! (or outside its Tensor.device scope)"
    end
    0
  end

  # ---- kernel-world vocabulary -------------------------------------------
  # These exist so a tensor_def body parses and type-checks.  They are read by
  # spinel-mlirgen --tensor and compiled to arith ops inside one
  # linalg.generic; they are never executed.  If one of them runs, a kernel
  # file was required into a program by mistake -- say so instead of quietly
  # computing something on the host.
  def *(other)
    raise TensorError, "Tensor#* is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def +(other)
    raise TensorError, "Tensor#+ is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def -(other)
    raise TensorError, "Tensor#- is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def /(other)
    raise TensorError, "Tensor#/ is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def relu
    raise TensorError, "Tensor#relu is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def matvec(other)
    raise TensorError, "Tensor#matvec is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def assign(other)
    raise TensorError, "Tensor#assign is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  # E038 (R004 stage 3 = design B): destination-passing at the CALL SITE.
  #
  #     y.assign!(x * 2.5 + y)
  #
  # `assign!` is to this surface what `.=` is to Julia (R004 s1.4): the one
  # character that says "write the whole fused expression into my storage".  The
  # statement is compiled -- not executed -- by `spinel-mlirgen --tensor --fuse`,
  # which folds the entire expression tree into ONE linalg.generic and rewrites
  # the statement into a call to the generated dispatch.  The program that gets
  # compiled is the rewritten one; this method exists so the ORIGINAL file still
  # parses and infers, and so that compiling the original by mistake fails here
  # instead of quietly computing nothing.
  #
  # `assign` (no bang) is the kernel-world root of a tensor_def body; `assign!`
  # is the host-world root of a fused statement.  They are deliberately spelled
  # differently: one lives in a file the program never requires, the other in the
  # program itself, and confusing them is exactly the mistake this message is
  # here to name.
  def assign!(other)
    raise TensorError, "Tensor#assign! is a FUSED call-site statement (R004 stage 3): " \
                       "it is compiled by `spinel-mlirgen --tensor --fuse`, which " \
                       "rewrites the statement into a generated dispatch. This binary " \
                       "was built from the ORIGINAL source, not the rewritten one"
  end

  def sum
    raise TensorError, "Tensor#sum is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def max
    raise TensorError, "Tensor#max is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end

  def min
    raise TensorError, "Tensor#min is kernel-world only: it may appear in a tensor_def " \
                       "body (compiled by spinel-mlirgen --tensor), never at run time"
  end
end
