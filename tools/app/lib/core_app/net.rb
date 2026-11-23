# frozen_string_literal: true
#
# tools/app/lib/core_app/net.rb -- the network file of the `udp:` channels
# (decision 0014 §5: endpoints and network interfaces come from Zephyr
# configuration and a file outside the repository).
#
# The build is given the file with --net. It names the interface the board
# sends on, the board's own address on it, and one endpoint per `udp:`
# channel; every value is a literal, and nothing else is read:
#
#   # comments and blank lines are ignored
#   interface swp0              # a Zephyr interface name (the NETC switch's user ports are swp<N>)
#   address 192.0.2.2           # the board's IPv4 address on it, or dhcp
#   netmask 255.255.255.0       # or dhcp, with address dhcp
#   channel frames 192.0.2.1 5029      # a udp: :out channel, the host and the UDP port it sends to
#   inbound keys 5030 from 192.0.2.1   # a udp: :in channel (decision 0025): the board's local
#                                      # port, and the one host address it accepts
#
# `address dhcp` and `netmask dhcp` (both, or neither) take the board's
# address by DHCP (decision 0024's amendment, item 4): the image then starts
# the interface's DHCP client instead of setting an address.
#
# Port 0 switches a channel off: the transport takes an :out channel's
# messages from the ring and discards them, counted (transport_udp.c.erb),
# and opens no socket for an :in channel, which then stays empty. An :in
# channel's source port is not restricted, and its socket is its own. The file is read
# whole and refused whole: a missing or repeated key, a channel line for a
# channel that is not `udp:` :out, an inbound line for one that is not
# `udp:` :in, a `udp:` channel without its line, or a value that
# is not an IPv4 dotted quad or a port is refused naming the line.
#
# `header` writes spc_net.h, the only place the values reach the image.
module CoreApp
  module Net
    class Error < StandardError; end

    Config = Struct.new(:path, :interface, :address, :netmask, :endpoints, :inbound, keyword_init: true)
    KEYS = %w[interface address netmask].freeze
    QUAD = /\A(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\z/
    # Zephyr's interface names are at most CONFIG_NET_INTERFACE_NAME_LEN
    # (15 by default) characters
    IFACE = /\A[A-Za-z][A-Za-z0-9_.-]{0,14}\z/

    module_function

    def quad?(s)
      m = QUAD.match(s) or return false
      m.captures.all? { |c| c.to_i <= 255 }
    end

    def read(path, app)
      udp = app.channels.select { |c| c.udp && c.direction == "out" }.map(&:name)
      udp_in = app.channels.select { |c| c.udp && c.direction == "in" }.map(&:name)
      File.file?(path) or raise Error, "#{path}: no network file (--net names it; it lives outside the repository)"
      seen = {}
      endpoints = {}
      inbound = {}
      File.foreach(path).with_index(1) do |raw, n|
        line = raw.sub(/#.*/, "").strip
        next if line.empty?
        f = line.split
        where = "#{path}:#{n}"
        case f[0]
        when *KEYS
          raise Error, "#{where}: #{f[0]} takes one value" unless f.size == 2
          raise Error, "#{where}: #{f[0]} is given twice" if seen.key?(f[0])
          if f[0] == "interface"
            raise Error, "#{where}: #{f[1].inspect} is not an interface name (a letter, then up to 14 letters, digits, _ . -)" unless IFACE.match?(f[1])
          else
            raise Error, "#{where}: #{f[0]} #{f[1].inspect} is not an IPv4 dotted quad or dhcp" unless f[1] == "dhcp" || quad?(f[1])
          end
          seen[f[0]] = f[1]
        when "channel"
          raise Error, "#{where}: channel takes a name, an IPv4 address and a port" unless f.size == 4
          name, addr, port = f[1..]
          raise Error, "#{where}: channel #{name} is not a udp: :out channel of #{app.path}#{udp.empty? ? ' (it has none)' : " (#{udp.join(', ')})"}" unless udp.include?(name)
          raise Error, "#{where}: channel #{name} is given twice" if endpoints.key?(name)
          raise Error, "#{where}: #{addr.inspect} is not an IPv4 dotted quad" unless quad?(addr)
          raise Error, "#{where}: the port #{port.inspect} is not an integer from 0 (off) to 65535" unless port.match?(/\A\d+\z/) && port.to_i <= 65_535
          endpoints[name] = [addr, port.to_i]
        when "inbound"
          raise Error, "#{where}: inbound takes a name, a port, `from` and an IPv4 address" unless f.size == 5 && f[3] == "from"
          name, port, _from, addr = f[1..]
          raise Error, "#{where}: inbound #{name} is not a udp: :in channel of #{app.path}#{udp_in.empty? ? ' (it has none)' : " (#{udp_in.join(', ')})"}" unless udp_in.include?(name)
          raise Error, "#{where}: inbound #{name} is given twice" if inbound.key?(name)
          raise Error, "#{where}: the port #{port.inspect} is not an integer from 0 (off) to 65535" unless port.match?(/\A\d+\z/) && port.to_i <= 65_535
          raise Error, "#{where}: #{addr.inspect} is not an IPv4 dotted quad" unless quad?(addr)
          inbound[name] = [port.to_i, addr]
        else
          raise Error, "#{where}: unknown line #{f[0].inspect}; the lines are #{KEYS.join(', ')}, channel and inbound"
        end
      end
      missing = KEYS - seen.keys
      raise Error, "#{path}: no #{missing.join(', ')} line" unless missing.empty?
      if (seen["address"] == "dhcp") != (seen["netmask"] == "dhcp")
        raise Error, "#{path}: address and netmask are both dhcp, or both IPv4 dotted quads"
      end
      absent = udp - endpoints.keys
      raise Error, "#{path}: no channel line for #{absent.join(', ')}" unless absent.empty?
      absent = udp_in - inbound.keys
      raise Error, "#{path}: no inbound line for #{absent.join(', ')}" unless absent.empty?
      Config.new(path: path, interface: seen["interface"], address: seen["address"], netmask: seen["netmask"], endpoints: endpoints,
                 inbound: inbound)
    end

    def header(config, app)
      out = +"/* generated by spinel-core-app build from the network file #{File.basename(config.path)}\n"
      out << " * (tools/app/lib/core_app/net.rb): the interface, the board's address, and\n"
      out << " * each udp: channel's endpoint. Port 0 switches a channel off. */\n"
      out << "#ifndef SPC_NET_H\n#define SPC_NET_H\n"
      out << "#define SPC_NET_IFACE \"#{config.interface}\"\n"
      if config.address == "dhcp"
        out << "#define SPC_NET_DHCP 1\n"
      else
        out << "#define SPC_NET_DHCP 0\n"
        out << "#define SPC_NET_ADDRESS \"#{config.address}\"\n"
        out << "#define SPC_NET_NETMASK \"#{config.netmask}\"\n"
      end
      app.channels.select(&:local_udp?).each do |c|
        addr, port = config.endpoints.fetch(c.name)
        out << "#define SPC_NET_#{c.name.upcase}_ADDR \"#{addr}\"\n"
        out << "#define SPC_NET_#{c.name.upcase}_PORT #{port}u\n"
      end
      out << "#endif\n"
    end

    # The network firmware's header (tools/app/launcher/net/forward.c), for
    # an application whose udp: channels the other core sends and receives:
    # the interface, the address or DHCP, the :out channel's destination (port
    # 0, sending off, when there is none), and the :in channel's local port and
    # accepted host (port 0, receiving off, when there is none).
    def launcher_header(config, out_c, in_c = nil)
      addr, port = out_c ? config.endpoints.fetch(out_c.name) : ["0.0.0.0", 0]
      in_port, in_host = in_c ? config.inbound.fetch(in_c.name) : [0, "0.0.0.0"]
      out = +"/* generated by spinel-core-app build from the network file #{File.basename(config.path)}\n"
      out << " * (tools/app/lib/core_app/net.rb) for the network firmware: :out #{out_c ? out_c.name : 'none'}, :in #{in_c ? in_c.name : 'none'}. */\n"
      out << "#ifndef SPC_NET_H\n#define SPC_NET_H\n"
      out << "#define SPC_NET_IFACE \"#{config.interface}\"\n"
      if config.address == "dhcp"
        out << "#define SPC_NET_DHCP 1\n"
      else
        out << "#define SPC_NET_DHCP 0\n#define SPC_NET_ADDRESS \"#{config.address}\"\n#define SPC_NET_NETMASK \"#{config.netmask}\"\n"
      end
      out << "#define SPC_NET_DEST_ADDR \"#{addr}\"\n#define SPC_NET_DEST_PORT #{port}\n"
      out << "#define SPC_NET_IN_PORT #{in_port}\n#define SPC_NET_IN_HOST \"#{in_host}\"\n#endif\n"
    end
  end
end
