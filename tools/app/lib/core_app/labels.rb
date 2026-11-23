# frozen_string_literal: true
#
# tools/app/lib/core_app/labels.rb -- the linked-image label check of the
# plan's "Channels": for each channel and operation, the four global labels
# spc_ring_<channel>_<put|get>_<copy|pub>_<begin|end> are present exactly
# once; each begin precedes its end; the copy span ends before the
# publication span begins (the payload is in the slot before the head or the
# tail is published: decision 0014 §5's order, which is the one property the
# labels exist to pin); and all four lie inside the function
# spc_channel_<channel>_<op> that the channel's call sites call. Decided
# from `object-symbols --addresses`, so the same reading serves ELF and
# Mach-O; where the format records no size for a function (Mach-O), the
# function ends where the next text symbol that is not one of its own labels
# begins, and a last function with nothing after it is refused as unbounded
# rather than passed.
require "open3"

module CoreApp
  module Labels
    class Error < StandardError; end

    Sym = Struct.new(:address, :size, :type, :name, keyword_init: true)

    module_function

    def read(image, symbols_tool:, env: {})
      raise Error, "no such image: #{image}" unless File.file?(image)
      text, err, status = Open3.capture3(env, symbols_tool, "--addresses", image)
      raise Error, "#{symbols_tool} failed on #{image}: #{err.strip}" unless status.success?
      text.lines.map do |l|
        a, s, t, n = l.chomp.split("\t", 4)
        Sym.new(address: a.to_i(16), size: s.to_i(16), type: t, name: n)
      end
    end

    # Returns the findings as strings, empty when every label is placed.
    def check(image, channels, symbols_tool:, env: {})
      syms = read(image, symbols_tool: symbols_tool, env: env)
      text = syms.select { |s| %w[T t].include?(s.type) }.sort_by(&:address)
      out = []
      channels.each do |ch|
        %w[put get].each do |op|
          fname = "spc_channel_#{ch}_#{op}"
          fn = text.select { |s| s.name == fname }
          if fn.size != 1
            out << "#{image}: #{fname} is defined #{fn.size} time(s)"
            next
          end
          fn = fn.first
          labels = %w[copy_begin copy_end pub_begin pub_end].map { |k| "spc_ring_#{ch}_#{op}_#{k}" }
          # the function's end, one past its last byte: from its size when the
          # format records one, else the next text symbol that is not one of
          # its own labels
          fn_end = if fn.size.positive?
                     fn.address + fn.size
                   else
                     nxt = text.find { |s| s.address > fn.address && !labels.include?(s.name) }
                     if nxt.nil?
                       out << "#{image}: #{fname} has no size and no text symbol after it; its extent is unknown"
                       next
                     end
                     nxt.address
                   end
          at = {}
          labels.each do |l|
            found = syms.select { |s| s.name == l }
            out << "#{image}: #{l} is present #{found.size} time(s), not once" unless found.size == 1
            at[l] = found.first&.address
          end
          next if at.values.any?(&:nil?)
          cb, ce, pb, pe = labels.map { |l| at[l] }
          h = ->(v) { format("%x", v) }
          out << "#{image}: spc_ring_#{ch}_#{op}_copy: begin #{h[cb]} does not precede end #{h[ce]}" unless cb < ce
          out << "#{image}: spc_ring_#{ch}_#{op}_pub: begin #{h[pb]} does not precede end #{h[pe]}" unless pb < pe
          out << "#{image}: spc_ring_#{ch}_#{op}: the copy span (#{h[cb]}..#{h[ce]}) does not end before the publication span begins (#{h[pb]}): the payload must be in the slot before the index is published" unless ce <= pb
          [[cb, ce, "copy"], [pb, pe, "pub"]].each do |b, e, span|
            inside = b >= fn.address && e < fn_end
            out << "#{image}: spc_ring_#{ch}_#{op}_#{span} (#{h[b]}..#{h[e]}) lies outside #{fname} (#{h[fn.address]}..#{h[fn_end]})" unless inside
          end
        end
      end
      out
    end
  end
end
