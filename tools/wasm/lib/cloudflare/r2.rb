# tools/wasm/lib/cloudflare/r2.rb -- R2 (object storage) from Ruby
# (E055; renamed from tools/wasm/spinel_host_r2.rb by E091).  Opt-in:
#
#   require "cloudflare/r2"
#   Cloudflare::R2.put("VAULT", "logo.png", png, content_type: "image/png")
#   Cloudflare::R2.get("VAULT", "logo.png")     # the same bytes, or nil
#   Cloudflare::R2.head("VAULT", "logo.png")    # size / etag / content_type
#   Cloudflare::R2.list("VAULT", prefix: "img/")
#   Cloudflare::R2.delete("VAULT", "logo.png")
#
# The contract that matters is byte transparency: whatever bytes go in come
# out, so a PNG, a gzip stream or a NUL-carrying blob is stored as itself and
# not as a mangled UTF-8 approximation of itself.
#
# ★ THE NAMESPACE IS THE VENDOR, NOT THE PLATFORM (R016 T-4, 2026-08-19).
#   `Cloudflare::` declares a dependency on who defines the semantics, runs the
#   service and bills for it -- NOT a binding to Workers.  R2 has an
#   S3-compatible HTTP API and would be reachable from anywhere if we
#   implemented that transport (P008 Phase 4.5).  Which platforms supply it
#   TODAY is a fact of tools/platform/menus.yaml (`{workers}`, because the
#   binding transport is all we have implemented), and the build-time refusal
#   is always the result of a menu lookup -- never an if-statement in code.
#
# The bucket name is the *binding* name from wrangler.toml, and the worker must
# list it in SPINEL_HOST_R2 -- a bucket is reachable only when the deployment
# says so, exactly as for KV (E014).
require "edge/bridge"
require "cloudflare/table"

module Cloudflare
  ffi_func :sp_host_r2_get,        [:str, :str], :int
  ffi_func :sp_host_r2_head,       [:str, :str], :int
  ffi_func :sp_host_r2_put,        [:str, :str, :str, :int, :str], :int
  ffi_func :sp_host_r2_delete,     [:str, :str], :int
  ffi_func :sp_host_r2_list,       [:str, :str, :int, :str], :int

  # One R2 object's description.  `body` is filled in only by get_object;
  # head and list leave it "" and `body?` says so.
  class R2Object
    attr_reader :key, :size, :etag, :uploaded, :content_type, :body

    def initialize(key, size, etag, uploaded, content_type, body)
      @key = key.to_s
      @size = size.to_i
      @etag = etag.to_s
      @uploaded = uploaded.to_s
      @content_type = content_type.to_s
      @body = body.to_s
    end

    def body?
      !@body.empty?
    end

    def to_s
      @key
    end
  end

  # The result of one R2 list page.  R2 pages; `truncated?` plus `cursor` is
  # how the next page is asked for, and the two are reported rather than looped
  # over internally -- a hidden loop is a hidden number of subrequests.
  #
  # ★ `keys` is stored, not derived.  Deriving it (`@objects.map(&:key)`, or a
  #   loop appending `@objects[i].key`) builds an Array whose element type the
  #   inference cannot see through the object, so it widens to TY_POLY -- and
  #   `join` on a poly Array goes through the generic Enumerable path, which
  #   reaches sp_enum_gen_pull and fails the build with `undefined symbol:
  #   swapcontext` (R003 §4-2: the fiber hole that never shows up in the
  #   generated C).  Filling it from the table's TEXT cells keeps it a String
  #   Array, and `keys.join(",")` links.  Measured, not guessed -- this file hit
  #   exactly that link error first.
  class R2Listing
    attr_reader :objects, :keys, :cursor

    def initialize(objects, keys, truncated, cursor)
      @objects = objects
      @keys = keys
      @truncated = truncated
      @cursor = cursor.to_s
    end

    def truncated?
      @truncated
    end

    def size
      @objects.length
    end
  end

  module R2
    # nil for a miss, a String (possibly "") for a hit.  A zero-byte object is
    # a hit and answers "".
    def self.get(bucket, key)
      return nil if Cloudflare.sp_host_r2_get(bucket.to_s, key.to_s) == 0
      Edge::Bridge.sp_host_res_body
    end

    # The same thing plus the object's metadata, as an R2Object.
    def self.get_object(bucket, key)
      return nil if Cloudflare.sp_host_r2_get(bucket.to_s, key.to_s) == 0
      # Sequenced into locals on purpose: as two arguments of one call, C leaves
      # their evaluation unsequenced (E014's note on the two drain slots).
      body = Edge::Bridge.sp_host_res_body
      meta = Edge::Bridge.sp_host_res_headers
      Cloudflare.build_r2_object(key.to_s, Edge::Bridge.parse_headers(meta), body)
    end

    # Metadata without transferring the body.  nil for a miss.
    def self.head(bucket, key)
      return nil if Cloudflare.sp_host_r2_head(bucket.to_s, key.to_s) == 0
      meta = Edge::Bridge.sp_host_res_headers
      Cloudflare.build_r2_object(key.to_s, Edge::Bridge.parse_headers(meta), "")
    end

    def self.key?(bucket, key)
      Cloudflare.sp_host_r2_head(bucket.to_s, key.to_s) == 1
    end

    # value is stored byte-exactly; content_type is remembered by R2 and comes
    # back from head/get_object/list.
    #
    # ★ The metadata block is built here rather than through
    #   Edge::Bridge.format_headers, and that is a measured constraint, not
    #   style.  `format_headers({ "content-type" => content_type })` passes a
    #   Hash whose VALUE is a nilable String (the kwarg default), i.e.
    #   Hash{String => TY_POLY}; Edge::HTTP.request already calls the same
    #   function with Hash{String => String}.  Two call sites with different
    #   value types made the shared function miscompile on wasm32 -- the first
    #   `.bytesize` on its result trapped with `memory access out of bounds`,
    #   and every caller was affected, including ones that had worked since
    #   E014.  A silent, action-at-a-distance failure of exactly the kind
    #   mvc-blog's VALIDATION.md catalogues.  One string concatenation, and the
    #   poly call site is gone.
    def self.put(bucket, key, value, content_type: nil)
      v = value.to_s
      meta = ""
      unless content_type.nil?
        meta = "content-type: " + content_type.to_s.gsub("\r", " ").gsub("\n", " ") + "\n"
      end
      Cloudflare.sp_host_r2_put(bucket.to_s, key.to_s, v, v.bytesize, meta)
      true
    end

    # Idempotent: deleting a key that is not there succeeds, because that is
    # what R2 itself does.  Use key? first if the distinction matters.
    def self.delete(bucket, key)
      Cloudflare.sp_host_r2_delete(bucket.to_s, key.to_s)
      true
    end

    # One page.  `limit` 0 means the host's default page size.  Keys come back
    # through the table slot and are therefore byte-exact -- a key containing a
    # newline cannot forge an extra entry, which is precisely why a listing is
    # not a text block.
    def self.list(bucket, prefix: "", limit: 0, cursor: "")
      n = Cloudflare.sp_host_r2_list(bucket.to_s, prefix.to_s, limit.to_i, cursor.to_s)
      table = Cloudflare::Table.read(n)
      meta = Edge::Bridge.parse_headers(Edge::Bridge.sp_host_res_headers)
      objects = []
      keys = []
      i = 0
      while i < table.length
        row = table[i]
        key = row.str("key")
        keys << key
        objects << R2Object.new(key, row.int("size"), row.str("etag"),
                                row.str("uploaded"), row.str("content_type"), "")
        i += 1
      end
      R2Listing.new(objects, keys, meta["truncated"].to_s == "1", meta["cursor"].to_s)
    end
  end

  def self.build_r2_object(key, meta, body)
    R2Object.new(key, meta["size"].to_i, meta["etag"].to_s, meta["uploaded"].to_s,
                 meta["content-type"].to_s, body)
  end
end
