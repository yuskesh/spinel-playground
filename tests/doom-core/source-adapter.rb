# frozen_string_literal: true
#
# tests/doom-core/source-adapter.rb — the source entries through the 0007 adapter registry.
#
# Loaded by tests/doom-core/source-port.rb when SOURCE_PORT_ADAPTER=LIB is set
# (with SOURCE_PORT_NATIVE and SOURCE_PORT_SESSION). LIB links the generated
# adapters of tests/doom-core/fixtures/source/*.contract, their one shared
# registry, and the kernel objects. The CALLER HOLDS NO POINTERS: every
# resident field the lane uses is registry storage allocated at its declared
# element and count, filled through `store`, read back through `load`, and
# handed to an entry as its id through the generated `invoke`. The port's names
# are defined over those calls, so source-port.rb's hooks and oracles are the
# same ones the direct and native lanes run.
#
# What 0007 decides here is not reimplemented: `invoke` refuses overlapping or
# stale participants and poisons the mutable ones on failure, and `core_state`
# is one id handed over once, with indices.
#
# These are the adapter's C operations, the ones the generated Ruby module binds
# with `ffi_func` for a program the pinned compiler builds; this lane reaches them
# from CRuby, where the game runs, through Fiddle.
require "fiddle"

module AdapterRoute
  ELEM = { "u8" => 1, "i32" => 2, "u32" => 3, "i64" => 4, "i8" => 5, "u16" => 6, "i16" => 7 }.freeze
  STATUS = { 1 => "ARGUMENT", 2 => "ARITHMETIC", 3 => "BOUNDS", 4 => "CAPACITY" }.freeze
  # A step that did not succeed ends the session: its mutable participants are
  # poisoned, so nothing may read them or name them in another step.
  class SessionFailed < StandardError; end
  POISON_LO = 0xdeadbeef
  POISON_HI = 0xcafebabe
  POISON = (POISON_HI << 32 | POISON_LO) - (1 << 64)
  I32 = Fiddle::TYPE_INT
  I64 = Fiddle::TYPE_LONG_LONG

  def self.open(lib)
    @lib = Fiddle.dlopen(lib)
    fn = ->(name, args, ret) { Fiddle::Function.new(@lib[name], args, ret) }
    @startup = fn.("spinel_adapter_registry_startup", [], I32)
    @allocate = fn.("spinel_adapter_registry_allocate", [I32, I64], I32)
    @store = fn.("spinel_adapter_registry_store", [I32, I64, I64], I32)
    @load = fn.("spinel_adapter_registry_load", [I32, I64], I64)
    @store_words = fn.("spinel_adapter_registry_store_i64_words", [I32, I64, I64, I64], I32)
    @load_words = fn.("spinel_adapter_registry_load_i64_words", [I32, I64, I32, I64, I64], I32)
    @release = fn.("spinel_adapter_registry_release", [I32], I32)
    @startup.call.zero? or raise "the adapter registry would not start"
    # EVERY ID THIS LANE ALLOCATES IS TRACKED FROM THE FIRST ONE, the helper cells
    # included, so every one is released. `@max_id` is the highest id the registry
    # ever handed out, which is what the release check probes up to.
    @ids = []
    @max_id = 0
    @invokes = {}
    @words = allocate("u32", 2)
    # SOURCE_PORT_ADAPTER_UNTRACKED=result: the control. The result cell is
    # allocated without being tracked, as it once was, and the release check has
    # to find it.
    @result = ENV["SOURCE_PORT_ADAPTER_UNTRACKED"] == "result" ? raw_allocate("i64", 1) : allocate("i64", 1)
    # A buffer with no elements, for a context that passes none: a live id.
    $empty = IdBuf.new(0, "u8")
  end

  def self.invoke_fn(entry, arity)
    @invokes[entry] ||= Fiddle::Function.new(@lib["spinel_adapter_dc_sp_#{entry}_invoke"], arity + [I32], I32)
  end

  class << self
    attr_reader :ids

    def raw_allocate(element, count)
      id = @allocate.call(ELEM.fetch(element), count)
      id.positive? or raise "the adapter would not allocate #{count} #{element}"
      @max_id = [@max_id, id].max
      id
    end
    def allocate(element, count)
      id = raw_allocate(element, count)
      @ids << id
      id
    end

    # Release every tracked id once, then ask the registry about EVERY id from 1
    # to the highest it handed out: ids are never reused, so each must now refuse
    # a release. One that accepts was allocated and never released -- whether or
    # not anything tracked it. Answers [allocated, released once, the ids that
    # accepted a second release].
    def release_all
      first = @ids.count { |id| release(id).zero? }
      leaked = (1..@max_id).select { |id| release(id).zero? }
      [@max_id, first, leaked]
    end
    def store(id, i, v) = @store.call(id, i, v)
    def load(id, i) = @load.call(id, i)
    def store_i64(id, i, v) = @store_words.call(id, i, v & 0xffffffff, (v >> 32) & 0xffffffff)
    def load_i64(id, i)
      st = @load_words.call(id, i, @words, 0, 1)
      return [st, nil] unless st.zero?
      lo = @load.call(@words, 0)
      hi = @load.call(@words, 1)
      v = (hi << 32) | lo
      [0, v >= (1 << 63) ? v - (1 << 64) : v]
    end
    def release(id) = @release.call(id)

    # One invoke: the result cell poisoned first, so an accepted call that wrote
    # nothing and a refused one that wrote anyway both show.
    def invoke(entry, types, *args)
      store_i64(@result, 0, POISON).zero? or raise "the adapter would not poison the result cell"
      status = invoke_fn(entry, types).call(*args, @result)
      _, got = load_i64(@result, 0)
      if status.zero?
        got == POISON and raise "#{entry}: an accepted invoke wrote no result"
      else
        got == POISON or raise "#{entry}: a refused invoke wrote a result"
      end
      [status, got]
    end
  end

  # Registry storage for one field: the lane's handle is the id and nothing else.
  class IdBuf
    attr_reader :id, :count, :element
    def initialize(count, element)
      @count = count
      @element = element
      @id = AdapterRoute.allocate(element, count)
    end
    def length = @count
    # Allocated storage is zeroed, so only the non-zero elements are stored.
    def load(bytes)
      width = @element == "u8" ? 1 : 8
      bytes.bytesize == @count * width or raise ArgumentError, "#{@count} #{@element} is not #{bytes.bytesize} bytes"
      if @element == "u8"
        bytes.each_byte.with_index { |b, i| b.zero? || AdapterRoute.store(@id, i, b).zero? || raise("store refused") }
      else
        bytes.unpack("q<*").each_with_index { |v, i| v.zero? || AdapterRoute.store_i64(@id, i, v).zero? || raise("store refused") }
      end
      self
    end
    def [](i)
      if @element == "u8"
        v = AdapterRoute.load(@id, i)
        v.negative? and raise IndexError, "load #{@id}[#{i}] answered #{v}"
        v
      else
        st, v = AdapterRoute.load_i64(@id, i)
        st.zero? or raise IndexError, "load #{@id}[#{i}] answered #{st}"
        v
      end
    end
    def []=(i, v)
      st = @element == "u8" ? AdapterRoute.store(@id, i, v) : AdapterRoute.store_i64(@id, i, v)
      st.zero? or raise IndexError, "store #{@id}[#{i}] answered #{st}"
    end
    def bytes = @element == "u8" ? (0...@count).map { |i| self[i] }.pack("C*") : (0...@count).map { |i| self[i] }.pack("q<*")
  end

  I = I64
  D = I32
  TYPES = {
    col: [D] * 6 + [I] * 12, span: [D] * 4 + [I] * 13, mjob: [D] * 4 + [I] * 12,
    none: [D] + [I] * 2, tex: [D] + [I] * 5, mask: [D] + [I] * 6, flat: [D] + [I] * 3,
    zone: [D] * 5 + [I] * 3, zalloc: [D] * 2 + [I], jreset: [D] * 2 + [I], exec: [D] * 17 + [I],
    pwall: [D] * 6 + [I] * 9, pspan: [D] * 6 + [I] * 9, pmask: [D] * 6 + [I] * 11, ph1: [D] + [I] * 2, ph3: [D] + [I] * 2,
    cdis: [D] * 6 + [I] * 4, cspan: [D] * 6 + [I] * 3, cmask: [D] * 8 + [I] * 4, call: [D] * 6 + [I] * 3,
    dplanes: [D] * 34 + [I] * 23, cplanes: [D] * 9 + [I] * 7,
    sbdraw: [D] * 21 + [I] * 8, hudraw: [D] * 9 + [I] * 2,
    pangle: [D] * 2 + [I] * 4,
    pdist: [D] * 3 + [I] * 4,
    sgscale: [D] * 3 + [I] * 4,
    lindex: [D] * 1 + [I] * 1,
    absang: [I] * 1,
    clipv: [D] * 2 + [I] * 3,
    segside: [D] * 4 + [I] * 3,
    fplane: [D] * 11 + [I] * 4,
    chplane: [D] * 9 + [I] * 4,
    ssclear: [D] * 4 + [I] * 1,
    crunch: [D] * 3 + [I] * 3,
    chkbbox: [D] * 8 + [I] * 5,
    vssort: [D] * 4 + [I] * 1,
    addspr: [D] * 39 + [I] * 10,
    segloop: [D] * 30 + [I] * 40
  }.freeze
end

# The port's names, over the adapter. UNLIKE THE NATIVE LANE, a step that is
# refused does not let the game go on: that is the diagnostic harness's
# behaviour, and here the caller is the session. The fault is recorded with the
# status by name and the session ends; source-port.rb reads nothing more back.
def adapter_call(entry, *args)
  $count["native:#{entry}"] += 1
  status, value = AdapterRoute.invoke(entry, AdapterRoute::TYPES.fetch(entry), *args)
  if status != 0
    where = "#{entry} #{AdapterRoute::STATUS.fetch(status, status)} (#{status}) #{$src_site} tic #{$tic} frame #{$frame}"
    fault("native-status", where)
    raise AdapterRoute::SessionFailed, where
  end
  value
end
def port_i64s(values) = AdapterRoute::IdBuf.new(values.length, "i64").load(values.pack("q<*"))
def port_bytes(str, _key = nil) = AdapterRoute::IdBuf.new(str.bytesize, "u8").load(str)
def port_screen(n) = AdapterRoute::IdBuf.new(n, "u8")
def dc_src_none(state, i_res, i_base) = adapter_call(:none, state.id, i_res, i_base)
def dc_src_texture_column(state, *scalars) = adapter_call(:tex, state.id, *scalars)
def dc_src_masked_post(state, *scalars) = adapter_call(:mask, state.id, *scalars)
def dc_src_span(state, *scalars) = adapter_call(:flat, state.id, *scalars)
def dc_draw_column(scr, _n_scr, cmap, _n_cmap, atlas, _n_atlas, wad, _n_wad, zonewin, _n_zonewin, state, *scalars)
  adapter_call(:col, scr.id, cmap.id, atlas.id, wad.id, zonewin.id, state.id, *scalars)
end
def dc_draw_span(scr, _n_scr, cmap, _n_cmap, flat, _n_flat, state, *scalars)
  adapter_call(:span, scr.id, cmap.id, flat.id, state.id, *scalars)
end
def dc_draw_masked_job(scr, _n_scr, cmap, _n_cmap, wad, _n_wad, zonebuf, _n_zonebuf, *scalars)
  adapter_call(:mjob, scr.id, cmap.id, wad.id, zonebuf.id, *scalars)
end
def dc_zone_window_into(wad, lump_pos, lump_size, next_lump, out, lumpnum, off, base)
  adapter_call(:zone, wad.id, lump_pos.id, lump_size.id, next_lump.id, out.id, lumpnum, off, base)
end
def dc_alloc_zone_window(state, i_nzone, zone_slots) = adapter_call(:zalloc, state.id, zone_slots.id, i_nzone)
def dc_jobs_reset(state, zero_slots, _n_zero_slots, i_fuzz_suffix) = adapter_call(:jreset, state.id, zero_slots.id, i_fuzz_suffix)
def dc_push_wall(*bufs_then_scalars) = adapter_call(:pwall, *bufs_then_scalars[0, 6].map(&:id), *bufs_then_scalars[6..])
def dc_push_span(*bufs_then_scalars) = adapter_call(:pspan, *bufs_then_scalars[0, 6].map(&:id), *bufs_then_scalars[6..])
def dc_push_masked(*bufs_then_scalars) = adapter_call(:pmask, *bufs_then_scalars[0, 6].map(&:id), *bufs_then_scalars[6..])
def dc_check_disjoint(*a) = adapter_call(:cdis, *a[0, 6].map(&:id), *a[6..])
def dc_check_span_disjoint(*a) = adapter_call(:cspan, *a[0, 6].map(&:id), *a[6..])
def dc_check_masked_k(*a) = adapter_call(:cmask, *a[0, 8].map(&:id), *a[8..])
def dc_check_wall_all(*a) = adapter_call(:call, *a[0, 6].map(&:id), *a[6..])
def dc_draw_planes(*a) = adapter_call(:dplanes, *(a[0, 34] + a[57, 11]).map(&:id), *a[34, 22], a[68], a[56])
def dc_clear_planes(*a) = adapter_call(:cplanes, *a[0, 9].map(&:id), *a[9..])
def dc_draw_statusbar(*a) = adapter_call(:sbdraw, *a[0, 21].map(&:id), *a[21..])
def dc_draw_hud(*a) = adapter_call(:hudraw, *a[0, 9].map(&:id), *a[9..])
def dc_point_to_angle(*a) = adapter_call(:pangle, *a[0, 2].map(&:id), *a[2..])
def dc_point_to_dist(*a) = adapter_call(:pdist, *a[0, 3].map(&:id), *a[3..])
def dc_scale_from_global_angle(*a) = adapter_call(:sgscale, *a[0, 3].map(&:id), *a[3..])
def dc_light_index(*a) = adapter_call(:lindex, *a[0, 1].map(&:id), *a[1..])
def dc_abs_angle(*a) = adapter_call(:absang, *a)
def dc_clip_value(*a) = adapter_call(:clipv, *a[0, 2].map(&:id), *a[2..])
def dc_point_on_seg_side(*a) = adapter_call(:segside, *a[0, 4].map(&:id), *a[4..])
def dc_find_plane(*a) = adapter_call(:fplane, *a[0, 11].map(&:id), *a[11..])
def dc_check_plane(*a) = adapter_call(:chplane, *a[0, 9].map(&:id), *a[9..])
def dc_clear_clip_segs(*a) = adapter_call(:ssclear, *a[0, 4].map(&:id), *a[4..])
def dc_crunch(*a) = adapter_call(:crunch, *a[0, 3].map(&:id), *a[3..])
def dc_check_bbox(*a) = adapter_call(:chkbbox, *a[0, 8].map(&:id), *a[8..])
def dc_sort_vissprites(*a) = adapter_call(:vssort, *a[0, 4].map(&:id), *a[4..])
def dc_add_sprites(*a) = adapter_call(:addspr, *a[0, 39].map(&:id), *a[39..])
def dc_render_seg_loop(*a) = adapter_call(:segloop, *a[0, 30].map(&:id), *a[30..])
def dc_mark_phase1(state, *scalars) = adapter_call(:ph1, state.id, *scalars)
def dc_mark_phase3(state, *scalars) = adapter_call(:ph3, state.id, *scalars)
