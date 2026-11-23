# examples/mvc-blog/native/edge/kv.rb -- a stand-in for edge/kv for native debugging
# (renamed from spinel_host.rb; the old name is frozen in tools/wasm/legacy).
#
# Why it is needed: in a wasm build, `--host-api` adds tools/wasm/lib to -I, so
# `require "edge/kv"` resolves to tools/wasm/lib/edge/kv.rb. That file holds
# `ffi_func :sp_host_*` declarations, so linking it natively gives
# `Undefined symbols: _sp_host_available` (the host thunks exist only on the wasm side).
#
# When running natively, add this directory to -I:
#
#   vendor/spinel/bin/spinel app.rb -I native -o /tmp/mvc-native
#
# Then `require "edge/kv"` resolves to this file.
# **This file never goes into a wasm build** (it is not added to -I there).
#
# The default answer is "there is no host bridge": native really has no Workers KV,
# so this is not a shim but the native truth.
#
# Sometimes, though, the native debugging loop should go **as far as persistence**. Then
#
#   MVC_NATIVE_KV=/tmp/mvc-kv.txt ./mvc-native /posts ''
#
# point a file with an environment variable as above, and a **test double** of KV is enabled.
# Its name and place say it is a double: it is not something that ships.
module Edge
  # A feature probe that raises no exception.
  def self.available?
    !ENV["MVC_NATIVE_KV"].to_s.empty?
  end

  # Native has no sending side (no stand-in for edge/http: what is absent stays absent).
  def self.fetch(url, method: "GET", body: nil, headers: nil)
    raise NotImplementedError, "Edge::HTTP is only available in a --host-api wasm build"
  end

  # ---- the test double's contents -------------------------------------------------
  # One line = "namespace\tkey\tpercent-escaped value".
  # It keeps only Workers KV's properties: **a miss is nil, an empty value is ""** (told apart).
  # The double has no list / delete either (the real v0 has none, so it stays without).
  def self.kv_path
    ENV["MVC_NATIVE_KV"].to_s
  end

  def self.kv_escape(s)
    out = ""
    i = 0
    while i < s.length
      c = s[i]
      if c == "%"
        out += "%25"
      elsif c == "\n"
        out += "%0A"
      elsif c == "\t"
        out += "%09"
      else
        out += c
      end
      i += 1
    end
    out
  end

  def self.kv_unescape(s)
    out = ""
    i = 0
    while i < s.length
      c = s[i]
      if c == "%" && i + 2 < s.length
        out += s[i + 1, 2].to_i(16).chr
        i += 3
      else
        out += c
        i += 1
      end
    end
    out
  end

  def self.kv_load
    rows = []
    path = kv_path
    return rows unless File.exist?(path)
    File.read(path).split("\n").each do |line|
      next if line.empty?
      parts = line.split("\t")
      rows << parts if parts.length >= 2
    end
    rows
  end

  module KV
    def self.get(namespace, key)
      Edge.kv_load.each do |row|
        if row[0] == namespace.to_s && row[1] == key.to_s
          return Edge.kv_unescape(row.length > 2 ? row[2] : "")
        end
      end
      nil
    end

    def self.put(namespace, key, value)
      out = ""
      wrote = false
      encoded = Edge.kv_escape(value.to_s)
      Edge.kv_load.each do |row|
        if row[0] == namespace.to_s && row[1] == key.to_s
          out += row[0] + "\t" + row[1] + "\t" + encoded + "\n"
          wrote = true
        else
          out += row[0] + "\t" + row[1] + "\t" + (row.length > 2 ? row[2] : "") + "\n"
        end
      end
      out += namespace.to_s + "\t" + key.to_s + "\t" + encoded + "\n" unless wrote
      File.write(Edge.kv_path, out)
      true
    end

    def self.key?(namespace, key)
      !get(namespace, key).nil?
    end
  end
end
