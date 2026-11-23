# frozen_string_literal: true
#
# tools/app/lib/spinel/core.rb -- the application declarations, under CRuby.
#
# Decision 0014 §2: an application's declarations are method calls that do
# nothing under CRuby. The application tool reads them from the AST; this file
# only lets the same file load in the host runner and the oracle. Each method
# accepts what the tool admits and returns nil.

def state(_name, _element, _count) = nil
# decision 0041 stage 2: a context's data stack; here it declares nothing,
# and run-host models the region (CoreApp::HostRunner::Scratch)
def scratch(_bytes, context: :thread) = nil
# Decision 0045: the buffer classes. The compiler recognises them by their
# spelling and never loads this; under CRuby each element method gives an
# Array of `count` elements, `fill` or the block's values. Under run-host,
# CoreApp::HostRunner puts its data stack model in front of Core::Buffer.
module Core
  ELEMENTS = %i[i8 i16 i32 i64 u8 u16 u32 f32 f64].freeze

  module Buffer
    ELEMENTS.each do |e|
      zero = e.to_s.start_with?("f") ? 0.0 : 0
      define_singleton_method(e) { |count, fill = zero| Array.new(count, fill) }
    end
  end

  module Table
    ELEMENTS.each do |e|
      define_singleton_method(e) { |count, &block| Array.new(count) { |i| block.call(i) } }
    end
  end
end
# `wake:` (decision 0028) names the contract channel whose doorbell releases
# the entry early; on the host it means nothing
def every_us(_period, _entry, context: :thread, wake: nil) = nil
def every_ms(_period, _entry, context: :thread, wake: nil) = nil
# `channel :name, contract: FILE` (decision 0027 stage 2) names no direction
def channel(_name, _direction = nil, **_options) = nil
# decision 0021: the session is placed by the build; on the host,
# CoreApp::SessionHost supplies it (and dtcm:, a placement, means nothing here)
def core_session(_entries_dir, dtcm: []) = nil

# Decision 0035 stage 2: `fiber_def :reader, max: 2` and the generated module
# `Reader` (start, resume, alive?). The build rewrites the declaration into
# static frames; here the same slot API runs on real Fibers, so the program
# runs unchanged. Every misuse is BOUNDS, as on the target: a slot outside
# 0...max, resume of a slot that is not live, start of a live one.
def fiber_def(name, max:)
  slots = Array.new(max)
  bounds = -> { raise CoreApp::Checked::Failure, "bounds" }
  in_range = ->(s) { s.is_a?(Integer) && s >= 0 && s < max }
  live = ->(s) { in_range.(s) && slots[s]&.alive? ? true : false }
  body = TOPLEVEL_BINDING.receiver
  mod = Module.new
  mod.define_singleton_method(:start) do |slot, *args|
    bounds.() if !in_range.(slot) || live.(slot)
    slots[slot] = Fiber.new { body.send(name, *args) }
    0
  end
  mod.define_singleton_method(:resume) do |slot, value|
    bounds.() unless live.(slot)
    slots[slot].resume(value)
  end
  mod.define_singleton_method(:alive?) do |slot|
    bounds.() unless in_range.(slot)
    live.(slot)
  end
  Object.const_set(name.to_s.split("_").map(&:capitalize).join, mod)
  nil
end

# Decision 0035, owner 2026-11-11: `enum_def :evens, max: 1` and the module
# `Evens` (start, next?, next, peek, alive?), the CORE form of
# Enumerator.new. The body `def evens(y, ...)` takes the yielder first. Here
# each slot is a real Enumerator. As on the target, next or peek with nothing
# left is BOUNDS, as is a slot outside 0...max or start of a live slot; a
# slot stays live until next? (or next or peek) finds the end.
def enum_def(name, max:)
  slots = Array.new(max)
  bounds = -> { raise CoreApp::Checked::Failure, "bounds" }
  in_range = ->(s) { s.is_a?(Integer) && s >= 0 && s < max }
  body = TOPLEVEL_BINDING.receiver
  fill = lambda do |s|
    bounds.() unless in_range.(s)
    return false unless slots[s]
    slots[s].peek
    true
  rescue StopIteration
    slots[s] = nil
    false
  end
  mod = Module.new
  mod.define_singleton_method(:start) do |slot, *args|
    bounds.() if !in_range.(slot) || slots[slot]
    slots[slot] = Enumerator.new { |y| body.send(name, y, *args) }
    0
  end
  mod.define_singleton_method(:next?) { |slot| fill.(slot) }
  mod.define_singleton_method(:next) { |slot| fill.(slot) ? slots[slot].next : bounds.() }
  mod.define_singleton_method(:peek) { |slot| fill.(slot) ? slots[slot].peek : bounds.() }
  mod.define_singleton_method(:alive?) do |slot|
    bounds.() unless in_range.(slot)
    slots[slot] ? true : false
  end
  Object.const_set(name.to_s.split("_").map(&:capitalize).join, mod)
  nil
end

# Decision 0041 stage 3 (owner 2026-11-14): `pool_def :node, max: 64` and
# the module `Node` (alloc, free, live?). The same slot numbers as on the
# target: alloc answers the most recently freed slot, otherwise the lowest
# slot never handed out, otherwise CAPACITY. free of a slot that is not
# allocated, and free or live? of a slot outside 0...max, are BOUNDS.
def pool_def(name, max:)
  live = Array.new(max, false)
  freed = []
  handed = 0
  bounds = -> { raise CoreApp::Checked::Failure, "bounds" }
  in_range = ->(s) { s.is_a?(Integer) && s >= 0 && s < max }
  mod = Module.new
  mod.define_singleton_method(:alloc) do
    s = if !freed.empty? then freed.pop
        elsif handed < max then (handed += 1) - 1
        else core_fail(:capacity)
        end
    live[s] = true
    s
  end
  mod.define_singleton_method(:free) do |slot|
    bounds.() unless in_range.(slot) && live[slot]
    live[slot] = false
    freed.push(slot)
    0
  end
  mod.define_singleton_method(:live?) do |slot|
    bounds.() unless in_range.(slot)
    live[slot]
  end
  Object.const_set(name.to_s.split("_").map(&:capitalize).join, mod)
  nil
end

# `core_extern` inside a module body. Under CRuby the generated host package
# supplies the module's methods; the declaration itself binds nothing.
class Module
  def core_extern(_name, **_keywords) = nil
end

# `core_fail(:capacity)` names one of the boundary's own statuses (0007). The
# host runner turns it into that status, as CORE does.
require "core_app/checked"
def core_fail(category) = raise(CoreApp::Checked::Failure, category.to_s)
