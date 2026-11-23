# frozen_string_literal: true
#
# E459: `gpu_buffer :name, :float|:int, <slot>` — the gpu-metal target's
# top-level buffer declarations. The gpu codegen (C) reads them out of the AST
# (cc_scan_gpu_buffers, the single authority: validation, slot map, element
# types, host binding all derive there). This module exists for ONE job, the
# same one Param/CommonFilter have: the declarations must not reach spinel's
# NATIVE codegen (which has no such notion and would refuse the call), so the
# CLI comments them out line-for-line in the copy handed to the native side —
# while the .ast keeps them, which is where the gpu codegen reads them.

module SpinelEbpf
  module GpuBuffer
    module_function

    # E467: `gpu_shared :name, :float|:int, <len>` is the second top-level
    # declaration with the same one job (threadgroup arrays; cc_scan_gpu_shared
    # is its single authority) -- stripped the same way for the native side.
    DECL_RE = /\A\s*gpu_(?:buffer|shared)\s+:[a-z_]\w*\s*,\s*:(?:float|int|atomic)\s*,\s*\d+\s*(?:#.*)?\z/.freeze

    def strip_declarations(source)
      source.each_line.map { |line| DECL_RE.match(line.chomp) ? "# (gpu declaration stripped for native codegen)\n" : line }.join
    end

    def present?(source)
      source.each_line.any? { |line| DECL_RE.match?(line.chomp) }
    end
  end
end
