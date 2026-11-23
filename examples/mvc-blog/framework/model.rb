# framework/model.rb -- the model base class, validation and the persistence adapters.
#
# This is not ActiveRecord. There is no DB, no SQL and no connection. There is
# **one kind of key-value store**: either Workers KV (through the host bridge),
# or, when there is none, a Hash inside the process.
#
# Serialization does not use JSON. `require "json"` needs a native `.o`, so
#   this target's Ruby cannot read JSON (`--host-api` in tools/wasm/README.md).
#   Instead it uses a one-blob-per-record format of **lines + percent escapes**:
#
#     title=%E3%81%93%E3%82%93%E3%81%AB%E3%81%A1%E3%81%AF
#     body=line 1%0Aline 2
#     created_at=1767225600
#
#   There are only 3 rules:
#     - one line = `field name=value`, split at the first "=" ("=" inside the value stays)
#     - only "%" "\n" "\r" in a value are escaped, as %25 / %0A / %0D
#     - `self.fields` sets the order of the fields (readers look them up by key, so any order works)
#   UTF-8 is not escaped, so a value in KV can be read by eye as it is.
#
# "Absent" and "empty" are told apart. store.get returns **nil** on a miss
#   and **""** for an empty value. Edge::KV is made that way, and this keeps it.
require "edge/kv"
require_relative "codec"

# ---- persistence adapters ------------------------------------------------------
class Store
  def get(key)
    nil
  end

  def put(key, value)
    false
  end

  def name
    "none"
  end

  def persistent?
    false
  end
end

# A Hash for one request only. The program is **instantiated per request**, so
# this disappears after one request. If production defaults to it, then
# "every request starts with an empty DB". It works for a demo, and that is
# exactly why KV is needed.
class MemoryStore < Store
  def initialize
    @data = {}
  end

  def get(key)
    @data.key?(key) ? @data[key] : nil
  end

  def put(key, value)
    @data[key] = value.to_s
    true
  end

  def name
    "memory"
  end

  def persistent?
    false
  end
end

# Workers KV, through the host bridge (--host-api).
# There is only get / put: KV v0 has no list / delete / TTL, so the
# index is kept by us (see Model#destroy below).
class KvStore < Store
  def initialize(namespace)
    @namespace = namespace
  end

  def get(key)
    Edge::KV.get(@namespace, key)
  end

  def put(key, value)
    Edge::KV.put(@namespace, key, value.to_s)
    true
  end

  def name
    "kv:" + @namespace
  end

  def persistent?
    true
  end
end

# The one place that decides which to use.
module Persistence
  def self.store
    @store ||= build_store
  end

  def self.build_store
    ns = kv_namespace
    return KvStore.new(ns) unless ns.empty?
    MemoryStore.new
  end

  # The reachable KV binding name. **Being bound is not enough to reach it**:
  # the name must be in SPINEL_HOST_KV in wrangler.toml (reachability is an explicit decision).
  def self.kv_namespace
    return "" unless Edge.available?
    raw = ENV["SPINEL_HOST_KV"].to_s
    return "" if raw.empty?
    raw.split(",")[0].to_s.strip
  end

  def self.adapter
    store.name
  end
end

# ---- Repo -- assembling and encoding keys --------------------------------------
# That these are **module functions** is not a design choice but this target's constraint.
#
#   Under Spinel's AOT compilation, calling a class method defined only on the base
#   class from an instance as `self.class.X` **does not pass the receiver's class and
#   resolves to the base class's implementation**. Implicit-receiver calls inside X
#   (`table` and the like) also become the base's, and what meant to write `posts:1`
#   writes `records:1`, with no exception raised.
#   (In the generated C the class token is fixed to Model, as in
#    `sp_Model_s_encode(((sp_Class){9, NULL}), ...)`. VALIDATION.md has the measurement)
#
#   Class methods a subclass **actually overrides** (`table` / `fields`) dispatch
#   correctly. So this layer is shaped as
#   "look up only the 2 overridden ones from the instance and pass the rest as arguments".
#   A module function has no class token, so there is no way to get it wrong.
module Repo
  def self.index_key(table)
    table + ":index"
  end

  def self.seq_key(table)
    table + ":seq"
  end

  def self.record_key(table, id)
    table + ":" + id.to_s
  end

  def self.next_id(table)
    st = Persistence.store
    raw = st.get(seq_key(table))
    n = (raw.nil? ? 0 : raw.to_i) + 1
    st.put(seq_key(table), n.to_s)
    n
  end

  # An id is kept as a **String**. As an integer, record_key's argument type would split
  # into String / Integer between callers, and the generated C's types would not match.
  def self.ids(table)
    out = []
    raw = Persistence.store.get(index_key(table))
    return out if raw.nil? || raw.empty?
    raw.split("\n").each { |s| out << s unless s.empty? }
    out
  end

  def self.encode(fields, attributes)
    out = ""
    fields.each do |f|
      value = attributes[f]
      out += f + "=" + Codec.percent_escape_record(value.nil? ? "" : value.to_s) + "\n"
    end
    out
  end

  def self.decode(blob)
    out = {}
    blob.split("\n").each do |line|
      next if line.empty?
      i = line.index("=")
      next if i.nil?
      out[line[0, i]] = Codec.percent_decode(line[(i + 1), line.length - i - 1], false)
    end
    out
  end
end

# ---- Model ---------------------------------------------------------------------
# A subclass overrides 3 **class methods**:
#
#   def self.table       -> "posts"                       the KV key prefix
#   def self.fields      -> ["title", "body"]             the attributes to persist
#   def self.validations -> [["title", "presence", 0]]    the validation rules
#
# **Class macros** like Rails' `validates :title, presence: true` **cannot be used**:
# user-defined method calls in a class body do not run under Spinel's AOT compilation
# (the README's "Writing Rails-style code in the Spinel subset" has the measurement).
# Declared with class methods that can be overridden, it is as declarative, and it surely works.
class Model
  attr_reader :attributes, :errors
  attr_accessor :id

  def self.table
    "records"
  end

  # The default is **not empty** on purpose. If the base returns `[]` and a subclass
  #   returns `["title", "body"]`, `sp_PolyArray *` and `sp_StrArray *` collide in the
  #   generated C and compilation fails. The default must have "the same shape as the subclass"
  #   (the README's "Writing Rails-style code in the Spinel subset").
  def self.fields
    ["_abstract"]
  end

  # A rule is always 3 elements: [field name, kind, argument]. The kind "none" does nothing.
  def self.validations
    [["_abstract", "none", 0]]
  end

  # Attributes are **looked up from the schema side (fields)**. Iterating the given Hash
  # with each and picking with `@attributes.key?(k)` can **quietly become false** on
  # this target (looking up a Hash{String=>String} with a key boxed as a block argument,
  # the generated C's include? dispatch has no case for STR_STR_HASH and falls to the
  # default; VALIDATION.md 4-2).
  #
  # As a side effect the design gets better too: what the schema has always exists, and
  # what it lacks never does ("absent" and "empty" are not mixed). Unknown keys from a form
  # are dropped here, so it also does the work of Rails' strong parameters.
  def initialize(attributes = {})
    @attributes = {}
    self.class.fields.each do |f|
      value = attributes[f]
      @attributes[f] = value.nil? ? "" : value.to_s
    end
    @errors = []
    @id = ""
  end

  def [](name)
    @attributes.key?(name) ? @attributes[name] : ""
  end

  def []=(name, value)
    @attributes[name] = value.to_s
  end

  def new_record?
    @id.to_s.empty?
  end

  # ---- validation --------------------------------------------------------------
  def valid?
    @errors = []
    self.class.validations.each do |rule|
      field = rule[0]
      kind = rule[1]
      arg = rule.length > 2 ? rule[2] : 0
      value = self[field]
      if kind == "presence"
        @errors << (field.to_s + " can't be blank") if value.strip.empty?
      elsif kind == "max_length"
        @errors << (field.to_s + " is too long (maximum is " + arg.to_s + " characters)") if value.length > arg.to_i
      end
    end
    @errors.empty?
  end

  # ---- persistence -------------------------------------------------------------
  # Only 2 are looked up from the instance: `self.class.table` and `self.class.fields`.
  # Subclasses really override both, so dispatch works (see the note on Repo above).
  def save
    return false unless valid?
    table = self.class.table
    st = Persistence.store
    if new_record?
      @id = Repo.next_id(table).to_s
      ids = Repo.ids(table)
      ids << @id
      st.put(Repo.index_key(table), ids.join("\n"))
    end
    st.put(Repo.record_key(table, @id), Repo.encode(self.class.fields, @attributes))
    true
  end

  # KV v0 has no delete, so the record is taken out of the index and its blob overwritten with an empty string.
  # "Not in the index" is the only truth; a blob left behind is an unreachable tombstone.
  def destroy
    table = self.class.table
    st = Persistence.store
    remaining = []
    Repo.ids(table).each { |i| remaining << i unless i == @id.to_s }
    st.put(Repo.index_key(table), remaining.join("\n"))
    st.put(Repo.record_key(table, @id), "")
    true
  end

  # ---- the class side ------------------------------------------------------------
  # This is the entrance called **statically by the subclass's name**, as in `Post.all`, so
  # dispatch of implicit receivers (`table` / `fields` / `find`) works.
  # Writing `self.table` resolves to the base, so do not write it.
  def self.ids
    Repo.ids(table)
  end

  def self.find(id)
    raw = Persistence.store.get(Repo.record_key(table, id))
    return nil if raw.nil? || raw.empty?
    record = new(Repo.decode(raw))
    record.id = id.to_s
    record
  end

  def self.all
    out = []
    ids.each do |i|
      record = find(i)
      out << record unless record.nil?
    end
    out
  end

  def self.count
    ids.length
  end
end
