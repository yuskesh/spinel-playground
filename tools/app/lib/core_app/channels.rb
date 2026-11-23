# frozen_string_literal: true
#
# tools/app/lib/core_app/channels.rb -- the channel package, generated per
# application (decision 0014 §5; the plan's "Channel package").
#
# For each `channel :name, :out|:in, size: s, depth: d, uart: true` (or `udp: true`) the package
# holds three things:
#
#   * the extern declarations of `Name.put` (an `:out` channel) or `Name.get`
#     (an `:in` channel), as CoreApp::Extern values the contracts are written
#     from: `put` guarded by `n >= 1 else argument`, `n <= size else bounds`
#     and `n <= len(data) else bounds`; `get` with the build-time requirement
#     `len(data) >= size else channel-buffer`;
#   * the C of the ring, rendered from tools/app/templates: single producer,
#     single consumer, `depth` slots of `size` bytes plus a length, head
#     published with release and read with acquire, tail the other way (C11
#     atomics), each operation in its own translation unit with labelled
#     copy and publication spans; and the transport thread over every
#     channel: the UART for `uart:` channels, and for `udp:` ones (:out only)
#     transport_udp.c, one socket per channel, with spc_net.h from the network
#     file (CoreApp::Net); a `udp:` channel whose other end is the other core
#     (`xcore`) has instead its put or its get over the OCRAM ring;
#   * the host simulator: a Ruby module with the same names and the same
#     semantics on a Ruby array, for the host runner and the oracle.
#
# The names `put` and `get` are FINAL (D4, decided by the owner 2026-09-23).
# They replace 0014's `send` and `recv` because `send` is `Object#send`: the
# pinned analyser expands a call named `send` as dynamic dispatch, and at the
# CRuby host `Telemetry.send(buf, n)` reaches `Object#send` unless the
# generated module shadows it.
require "erb"
require_relative "app_model"
require_relative "net"
require_relative "core_channel"

module CoreApp
  module Channels
    PUT = "put"
    GET = "get"

    ChannelPackage = Struct.new(:externs, :c_files, :host_source, :ruby_source, keyword_init: true)

    module_function

    # `xi_base` is the number of externs the trace numbers before the
    # channels' (the board's members): a verification build records each
    # channel extern's calls under xi_base + the channel's index (Task 11).
    # `transport: true` renders the transport even without channels: a
    # verification build drains the recorder's rings through it (Task 11).
    # `net` is the network file read by CoreApp::Net, for an application with
    # `udp:` channels: it becomes spc_net.h beside transport_udp.c. Without
    # one the package still renders (package, admit), and the build refuses.
    def generate(app, xi_base: 0, transport: false, net: nil)
      externs = app.channels.map { |c| extern_of(c) }
      ChannelPackage.new(externs: externs, c_files: c_files(app, xi_base: xi_base, transport: transport, net: net), host_source: host_source(app),
                         ruby_source: ruby_source(app))
    end

    # A contract channel's (decision 0027 stage 2): `put` takes each scalar
    # field as an argument and each array as a buffer; `get` writes every
    # field, the scalars too, into a buffer. A u8, u16 or u32 scalar is a
    # u32 parameter and an i8, i16 or i32 one an i32, with a domain guard
    # when the field is narrower (owner, 2026-10-26); an array's length is a
    # static. The application tool has u8, u32 and i32 state, so an i8, u16
    # or i16 array is refused at its declaration.
    PARAM = { "u8" => "u32", "u16" => "u32", "u32" => "u32", "i8" => "i32", "i16" => "i32", "i32" => "i32" }.freeze
    BUF = { "u8" => "u8", "u16" => "u32", "u32" => "u32", "i8" => "i32", "i16" => "i32", "i32" => "i32" }.freeze
    NARROW = { "u8" => [nil, 255], "u16" => [nil, 65_535], "i8" => [-128, 127], "i16" => [-32_768, 32_767] }.freeze
    CTYPE = { "u8" => "uint8_t", "u32" => "uint32_t", "i32" => "int32_t" }.freeze

    def contract_extern(c)
      k = c.contract
      if c.direction == "out"
        params = k.fields.map do |f|
          f.array ? ExternParam.new(name: f.name, kind: :buffer, type: f.type) : ExternParam.new(name: f.name, kind: :scalar, type: PARAM[f.type])
        end
        guards = k.fields.reject(&:array).flat_map do |f|
          lo, hi = NARROW[f.type]
          [("#{f.name} >= #{lo} else argument" if lo), ("#{f.name} <= #{hi} else argument" if hi)].compact
        end
        Extern.new(module_name: c.module_name, name: PUT, params: params, returns: "i32", reads: k.fields.select(&:array).map(&:name), writes: [],
                   isr_ok: true, bound: "iterations #{k.msg_bytes}", provider: "<generated channel C>", guards: guards,
                   statics: k.fields.select(&:array).map { |f| "len(#{f.name}) >= #{f.count} else channel-buffer" }, origin: "channel", line: c.line)
      else
        params = k.fields.map { |f| ExternParam.new(name: f.name, kind: :buffer, type: f.array ? f.type : BUF[f.type]) }
        Extern.new(module_name: c.module_name, name: GET, params: params, returns: "i32", reads: [], writes: k.fields.map(&:name),
                   isr_ok: true, bound: "iterations #{k.msg_bytes}", provider: "<generated channel C>", guards: [],
                   statics: k.fields.map { |f| "len(#{f.name}) >= #{f.count} else channel-buffer" }, origin: "channel", line: c.line)
      end
    end

    # The C of a contract channel's operation, from channel_core.{h,c}.erb.
    def contract_files(c)
      k = c.contract
      idx, offset = c.ring
      role = c.direction == "out" ? "producer" : "consumer"
      core = c.direction == "out" ? k.from : k.to
      base = core == "cm7" ? "SPC_RING_M7_BASE" : "SPC_RING_M33_BASE"
      from_id = CoreChannel::CORE_IDS[k.from]
      to_id = CoreChannel::CORE_IDS[k.to]
      digest_hi = format("0x%08x", k.digest[0, 8].to_i(16))
      digest_lo = format("0x%08x", k.digest[8, 8].to_i(16))
      init_index = 0
      bell = c.doorbell # decision 0028: nil, or {notify:, want:, gi:, gcr:, unrung:}
      put_params = k.fields.map { |f| f.array ? "const #{CTYPE[f.type]} *#{f.name}, uint32_t #{f.name}_len" : "#{PARAM[f.type] == 'u32' ? 'uint32_t' : 'int32_t'} #{f.name}" }.join(", ")
      get_params = k.fields.map { |f| t = f.array ? f.type : BUF[f.type]; "#{CTYPE[t]} *#{f.name}, uint32_t #{f.name}_len" }.join(", ")
      get_cast = { "u8" => "(uint8_t)", "u16" => "", "u32" => "", "i8" => "(int32_t)(int8_t)", "i16" => "(int32_t)(int16_t)", "i32" => "(int32_t)" }
      { "channel_#{c.name}.h" => render("channel_core.h.erb", binding),
        "channel_#{c.name}_#{role == 'producer' ? 'put' : 'get'}.c" => render("channel_core.c.erb", binding) }
    end

    def extern_of(c)
      return contract_extern(c) if c.contract

      if c.direction == "out"
        Extern.new(module_name: c.module_name, name: PUT,
                   params: [ExternParam.new(name: "data", kind: :buffer, type: "u8"),
                            ExternParam.new(name: "n", kind: :scalar, type: "u32")],
                   returns: "i32", reads: ["data"], writes: [], isr_ok: true,
                   bound: "iterations #{c.size}", provider: "<generated channel C>",
                   guards: ["n >= 1 else argument", "n <= #{c.size} else bounds", "n <= len(data) else bounds"],
                   statics: [], origin: "channel", line: c.line)
      else
        Extern.new(module_name: c.module_name, name: GET,
                   params: [ExternParam.new(name: "data", kind: :buffer, type: "u8")],
                   returns: "i32", reads: [], writes: ["data"], isr_ok: true,
                   bound: "iterations #{c.size}", provider: "<generated channel C>",
                   guards: [], statics: ["len(data) >= #{c.size} else channel-buffer"],
                   origin: "channel", line: c.line)
      end
    end

    # The declaration form, for the record and for the packaged root's
    # module list: empty modules, since the kernel reads the contract.
    def ruby_source(app)
      lines = ["# generated channel declarations (decision 0014 §5); the contracts carry them"]
      app.channels.each do |c|
        e = extern_of(c)
        lines << "module #{c.module_name}"
        lines << "  # core_extern :#{e.name}, params: {#{e.params.map { |p| "#{p.name}: #{p.buffer? ? "[:buf, :#{p.type}]" : ":#{p.type}"}" }.join(', ')}}, returns: :#{e.returns}, isr_ok: true, bound: \"#{e.bound}\""
        lines << "end"
      end
      lines.join("\n") + "\n"
    end

    # The C of the package, as {file name => text}, rendered from
    # tools/app/templates: per channel a header, the storage
    # (channel_<name>_ring.c), and the put and the get each alone in its own
    # translation unit with global labels around its copy and its
    # publication (the plan's "Channels"); and one transport_uart.c for the
    # application (none without channels), with transport_udp.c and spc_net.h
    # beside it when a channel is `udp:`. The build compiles each unit on
    # its own, without link-time optimisation.
    TEMPLATES = File.expand_path("../../templates", __dir__)

    def render(name, binding_)
      ERB.new(File.read(File.join(TEMPLATES, name)), trim_mode: "<>").result(binding_)
    end

    def c_files(app, xi_base: 0, transport: false, net: nil)
      files = {}
      app.channels.each_with_index do |c, ci|
        xi = xi_base + ci
        if c.contract
          files.merge!(contract_files(c))
          next
        end
        if c.xcore
          # the other end is the other core: an :out channel's put writes the
          # outbound OCRAM ring, an :in channel's get reads the inbound one
          stride, offset = c.ring
          if c.direction == "out"
            files["channel_#{c.name}.h"] = render("channel_xcore.h.erb", binding)
            files["channel_#{c.name}_put.c"] = render("channel_xcore.c.erb", binding)
          else
            files["channel_#{c.name}.h"] = render("channel_xcore_in.h.erb", binding)
            files["channel_#{c.name}_get.c"] = render("channel_xcore_in.c.erb", binding)
          end
          next
        end
        files["channel_#{c.name}.h"] = render("channel.h.erb", binding)
        files["channel_#{c.name}_ring.c"] = render("channel_ring.c.erb", binding)
        %w[put get].each do |op|
          files["channel_#{c.name}_#{op}.c"] = render("channel.c.erb", binding)
        end
      end
      # no channels, no transport: nothing to drain and nothing to fill
      files["transport_uart.c"] = render("transport_uart.c.erb", binding) if transport || app.channels.any?(&:framed?)
      # the udp: channels this core sends: drained by the same thread, through their own unit
      udp = app.channels.select(&:local_udp?)
      unless udp.empty?
        files["transport_udp.c"] = render("transport_udp.c.erb", binding)
        files["spc_net.h"] = Net.header(net, app) if net
      end
      files
    end

    # The OCRAM rings' slot strides and offsets (tools/app/ring/ring_abi.h,
    # version 5): a slot holds the length word and `size` bytes, 32-byte
    # aligned. The outbound ring's slots follow the 512-byte header and the
    # inbound ring's follow the outbound ring's (or the header, when there is
    # no outbound ring). Returns {channel => [stride, offset]} and the end of
    # the last ring's slots.
    RING_OFFSET = 512
    RING_BYTES = 128 * 1024
    def ring_stride(c) = ((4 + c.size + 31) / 32) * 32

    def ring_layout(out_c, in_c)
      at = RING_OFFSET
      layout = {}
      [out_c, in_c].compact.each do |c|
        layout[c] = [ring_stride(c), at]
        at += c.depth * ring_stride(c)
      end
      [layout, at]
    end

    # The M33's header of the rings' geometry (tools/app/launcher/net/ring_init.c
    # and forward.c): the outbound ring's as SPC_RING_*, the inbound ring's as
    # SPC_RING_IN_*; a ring the application does not have has depth 0.
    def ring_geometry_h(out_c, in_c)
      out = +"/* generated by spinel-core-app build: the OCRAM rings (tools/app/ring/ring_abi.h, version 5):\n"
      out << " * outbound #{out_c ? "channel #{out_c.name}" : 'none'}, inbound #{in_c ? "channel #{in_c.name}" : 'none'} */\n"
      { "SPC_RING" => out_c, "SPC_RING_IN" => in_c }.each do |pre, c|
        stride, offset = c ? c.ring : [0, 0]
        out << "#define #{pre}_DEPTH #{c ? c.depth : 0}u\n#define #{pre}_STRIDE #{stride}u\n"
        out << "#define #{pre}_MAX_LEN #{c ? c.size : 0}u\n#define #{pre}_OFFSET #{offset}u\n#define #{pre}_INIT_INDEX 0u\n"
      end
      out
    end

    # The host simulator: the same semantics on a Ruby array. The runner
    # attaches a recorder through `CoreApp::ChannelSim.recorder=`; without one
    # the simulators just move messages.
    def host_source(app)
      out = +"# generated channel simulators (decision 0014 §5), for CRuby\n"
      out << "require \"core_app/channel_sim\"\n"
      out << "require \"core_app/core_channel_sim\"\n" if app.channels.any?(&:contract)
      app.channels.each do |c|
        out << "module #{c.module_name}\n"
        if c.contract
          # decision 0027 stage 2: the typed message, packed as the slot holds it
          k = c.contract
          fields = k.fields.map { |f| [f.name, f.type, f.array ? f.count : nil] }
          out << "  SIM = CoreApp::CoreChannelSim.new(#{c.name.inspect}, #{c.direction.inspect}, #{k.depth}, #{fields.inspect})\n"
          args = k.fields.map(&:name).join(", ")
          out << (c.direction == "out" ? "  def self.put(#{args}) = SIM.put(#{args})\n" : "  def self.get(#{args}) = SIM.get(#{args})\n")
          out << "end\n"
          next
        end
        out << "  SIM = CoreApp::ChannelSim.new(#{c.name.inspect}, #{c.direction.inspect}, #{c.size}, #{c.depth})\n"
        if c.direction == "out"
          out << "  def self.put(data, n) = SIM.put(data, n)\n"
        else
          out << "  def self.get(data) = SIM.get(data)\n"
        end
        out << "end\n"
      end
      out
    end
  end
end
