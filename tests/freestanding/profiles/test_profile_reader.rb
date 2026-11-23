#!/usr/bin/env ruby
# frozen_string_literal: true
#
# tests/freestanding/profiles/test_profile_reader.rb -- the shipped profiles are
# read, and the refusals that must stay refusals stay. Ported from spinel-llvm
# 463d49dd tools/mlir/native/ab/test_e162_profile_reader.rb (E162 F-233), with
# its three fixtures from docs/experiments/results/E162/cp1.
#
#   SPINEL_CORE_BUILD=<build dir> ruby tests/freestanding/profiles/test_profile_reader.rb
#
# What it pins:
#   * the shipped profile SET, in both forms, exactly -- one appearing or
#     disappearing is a failure, not a no-op. This repository ships one more
#     pre-T5 profile than spinel-llvm did, the x86_64 host profile.
#   * every pre-T5 profile is accepted by the native reader;
#   * a trap hook in the bare allowlist is not a collision;
#   * an extern entry that hits the trap hook, or repeats a symbol, is still
#     refused, as an undef-allowlist violation.
#   * ADDED HERE: every platform-first (T-5) profile expands through
#     tools/platform/menus.yaml and emits a trap-only kernel to an object for its
#     own target. spinel-llvm's test noted that the native reader could not read
#     T-5 yet; the emitter now does, and nothing else in this port shows it.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class ProfileReaderTest < Minitest::Test
  HERE = File.expand_path(File.dirname(__FILE__))
  REPO = File.expand_path("../../..", HERE)
  FIX  = File.join(HERE, "fixtures")
  TD   = ENV.fetch("SPINEL_TYPEDUMP", File.join(REPO, "tools/contract/build/spinel-typedump"))
  BIN  = File.join(ENV.fetch("SPINEL_CORE_BUILD", File.join(REPO, "tools/mlir/native/build")), "bin")
  PROFILE_DIR = File.join(REPO, "tools/freestanding/profiles")
  FS_DECL = File.join(REPO, "tools/freestanding/spinel/freestanding.rb")

  SHIPPED_PRE_T5 = %w[cortex-m33-zephyr.yaml riscv32-zephyr.yaml
                      wasm32-worker.yaml x86_64-linux-host.yaml].freeze
  SHIPPED_T5 = %w[workers-wasm32.yaml zephyr-cortex-m33.yaml
                  zephyr-riscv32.yaml].freeze
  # The object format each platform-first profile must produce, from `file`.
  T5_OBJECT = { "workers-wasm32.yaml"    => /WebAssembly/,
                "zephyr-cortex-m33.yaml" => /ELF 32-bit LSB relocatable, ARM/,
                "zephyr-riscv32.yaml"    => /ELF 32-bit LSB relocatable, UCB RISC-V/ }.freeze
  LISTS_TRAP_HOOK = %w[cortex-m33-zephyr.yaml riscv32-zephyr.yaml
                       x86_64-linux-host.yaml].freeze
  COLLISION_CASES = %w[r29_extern_hits_trap_hook.yaml r30_extern_dup_symbol.yaml].freeze

  # The fixture requires spinel/freestanding beside itself; it is staged with
  # the repository's declaration surface rather than a second copy of it.
  def check(profile)
    Dir.mktmpdir do |w|
      FileUtils.mkdir_p(File.join(w, "spinel"))
      FileUtils.cp(FS_DECL, File.join(w, "spinel"))
      FileUtils.cp(File.join(FIX, "c01_scalar.rb"), w)
      Open3.capture3(File.join(BIN, "spinel-fs-check"),
                     "--profile", profile, "--source", File.join(w, "c01_scalar.rb"),
                     "--typedump", TD, chdir: w)
    end
  end

  def test_shipped_profile_set_is_the_declared_one
    on_disk = Dir.children(PROFILE_DIR).select { |f| f.end_with?(".yaml") }
    # Split by FORM: pre-T5 has a `target:` section, T-5 starts with `platform:`.
    pre_t5 = on_disk.select { |f| File.read(File.join(PROFILE_DIR, f)) =~ /^target:\s*$/ }
    t5 = on_disk - pre_t5
    assert_equal SHIPPED_T5.sort, t5.sort, "the shipped T-5 profiles changed: #{t5.sort.inspect}"
    assert_equal SHIPPED_PRE_T5.sort, pre_t5.sort, "the shipped pre-T5 profiles changed: #{pre_t5.sort.inspect}"
  end

  def test_native_accepts_every_shipped_pre_t5_profile
    SHIPPED_PRE_T5.each do |name|
      out, err, st = check(File.join(PROFILE_DIR, name))
      assert st.success?, "the native reader refused the shipped profile #{name}\n#{out}#{err}"
    end
  end

  def test_trap_hook_in_the_bare_allowlist_is_not_a_collision
    listing = SHIPPED_PRE_T5.select do |name|
      text = File.read(File.join(PROFILE_DIR, name))
      hook = text[/^\s*trap_hook:\s*(\S+)/, 1]
      hook && text[/^\s*externs:\s*\n((?:\s*-\s*\S+\s*\n)+)/, 1].to_s.include?(hook)
    end
    assert_equal LISTS_TRAP_HOOK.sort, listing.sort,
                 "the set of shipped profiles listing the trap hook in the bare allowlist changed"
    refute_empty listing, "no profile lists the trap hook: this axis would be vacuous"
    listing.each do |name|
      out, err, st = check(File.join(PROFILE_DIR, name))
      assert st.success?, "#{name}: the trap hook in the bare allowlist was read as a collision\n#{out}#{err}"
    end
  end

  def test_callable_extern_collisions_are_still_refused
    COLLISION_CASES.each do |name|
      out, err, st = check(File.join(FIX, name))
      refute st.success?, "#{name}: a real collision was accepted\n#{out}"
      assert_match(/spinel-fs:P2: undef-allowlist-violation:/, err, "#{name}: the refusal's class changed")
    end
  end

  def test_every_platform_first_profile_emits_for_its_target
    SHIPPED_T5.each do |name|
      Dir.mktmpdir do |w|
        FileUtils.mkdir_p(File.join(w, "spinel"))
        FileUtils.cp(FS_DECL, File.join(w, "spinel"))
        FileUtils.cp(File.join(FIX, "c01_scalar.rb"), w)
        _, err, st = Open3.capture3(File.join(BIN, "spinel-fs-emit"), "c01_scalar.rb",
                                    "--freestanding", "--profile", File.join(PROFILE_DIR, name),
                                    "-o", "k.o", "--emit-header", "k.h", "--typedump", TD, chdir: w)
        assert st.success?, "#{name}: the kernel did not emit\n#{err}"
        kind, = Open3.capture2("file", File.join(w, "k.o"))
        assert_match T5_OBJECT.fetch(name), kind, "#{name}: the object is not for its target"
      end
    end
  end
end
