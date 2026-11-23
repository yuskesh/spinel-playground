# frozen_string_literal: true
#
# tools/doom/contract_reader.rb — the one place this repository's Ruby tools
# read the pinned contract reader.
#
# tools/mlir/native/lib/Contract/Reader.cpp is the reference for the wire
# format and tools/mlir/native/lib/Core/Input.cpp for the input discipline.
# Rather than document that a second tool makes none of that reader's checks,
# the SUBSET the Ruby side consumes is limited here and validated here, once:
#
#   * every record tag is one of the eight the reader emits;
#   * a node is declared exactly once;
#   * a field key is set at most once per node;
#   * no field is set on an undeclared node;
#   * every `R` other than -1, and every element of an `A`, names a declared
#     node -- an `A` value is a COMMA-SEPARATED LIST and an empty one is the
#     empty array, and on an `R` only -1 means "no reference" while a missing
#     field is a different thing and must never become node 0;
#   * a tabular face has a header and every row has the header's width.
#
# `I` values are NOT links. `node_file` holds a FILE id and the rest are plain
# integers, so validating them against the node set would be a category error.
#
# EACH PARSE IS ITS OWN NODE-ID NAMESPACE. Two files read by two reader runs
# both start at node 0 and mean different things by it. Nothing here joins ids
# across parses, and a caller comparing two parses must compare by name.

require "digest"

module ContractReader
  AST_TAGS = %w[SOURCE_FILE FILE ROOT N S I R A].freeze

  class Error < StandardError; end

  # One reader invocation. `--inputs-out` goes BEFORE the mode, because the
  # mode has always been the final argument and a wrapper around the reader may
  # key on that; Input.cpp:111-113 says the same and for the same reason.
  def self.run_face(reader, entry, mode, ledger_path)
    out = IO.popen([reader, entry, "--inputs-out=#{ledger_path}", mode], "rb", &:read)
    raise Error, "the reader failed on #{entry} #{mode}" unless $?.success?
    out.force_encoding(Encoding::BINARY)
  end

  # The ledger's wire contract, and the whole of it: a non-empty sequence of
  # non-empty NUL-terminated records of realpath-resolved absolute paths. This
  # is Input.cpp's checkLedger minus its single-file rule; a multi-file closure
  # has many, so the caller compares the set instead of one name.
  def self.ledger_records(path, face)
    bad = ->(m) { raise Error, "input ledger (#{face}): #{m}" }
    File.exist?(path) or bad.call("the reader wrote no ledger")
    bytes = File.binread(path)
    bad.call("the reader wrote an empty ledger") if bytes.empty?
    bad.call("the ledger does not end in a NUL; it is truncated") unless bytes.getbyte(-1) == 0
    recs = bytes.split("\0", -1)
    recs.pop
    bad.call("the ledger holds no records") if recs.empty?
    bad.call("the ledger holds an empty record") if recs.any?(&:empty?)
    recs.map { |r| r.force_encoding(Encoding::UTF_8) }
  end

  def self.decode_path(p)
    p.gsub(/%([0-9A-Fa-f]{2})/) { [$1].pack("H2") }
  end

  # A tabular face (nodes, methods, globals). Returns the data rows.
  def self.tsv(raw, face, want_cols)
    head = nil
    rows = []
    raw.each_line.with_index(1) do |ln, lineno|
      f = ln.chomp.split("\t", -1)
      if head.nil?
        head = f
        head.length >= want_cols or
          raise Error, "the #{face} face's header has #{head.length} column(s), " \
                       "fewer than the #{want_cols} this reads: #{head.join(',')}"
        next
      end
      f.length == head.length or
        raise Error, "#{face} line #{lineno}: #{f.length} column(s), the header declares #{head.length}"
      rows << f
    end
    head or raise Error, "the #{face} face is empty; it has not even a header"
    rows
  end

  # Both faces of one parse must agree on the kind of every node they both
  # declare, as tools/mlir/native/lib/Contract/Reader.cpp requires
  # ("kind-mismatch"). The analysis can replace a node in place in the table
  # the nodes face reads, and a reader that takes links from the ast and kinds
  # from the nodes face then reads neither program: upstream 06430db8b resets
  # `s.to_s` under a String mutator to a NilNode, and the audit saw a nil
  # receiver, recording no store and no gap. A row only the nodes face has (an
  # instantiated copy) has no ast kind to disagree with. `kinds` is the nodes
  # face as id => kind.
  def self.check_kinds(ast, kinds)
    kinds.each do |id, k|
      a = ast.kind(id)
      next if a.nil? || a == k
      raise Error, "kind-mismatch: node #{id} ast '#{a}' nodes '#{k}'"
    end
  end

  # The Ruby name of each class spelling the reader gives, as a hash from
  # spelling to name.
  #
  # The analysis gives some nested classes their C spelling, `Outer__Leaf`:
  # one whose leaf is also a builtin class's name, and one whose leaf two
  # namespaces both define (upstream #3781). Upstream 84538745c put Random in
  # the builtin table, so `Doom::Random` now reads as `Doom__Random`, as
  # `Doom::Time` already did. These tools key a class by the Ruby name it is
  # written as, so a spelling maps back to its leaf -- but only when the
  # program has exactly one class with that leaf. Two would become one key,
  # so that is refused, naming both spellings, and never merged.
  def self.ruby_class_names(spellings)
    by_leaf = Hash.new { |h, k| h[k] = [] }
    spellings.uniq.each do |sp|
      leaf = sp.include?("__") ? sp.split("__").last.to_s : sp
      by_leaf[leaf.empty? ? sp : leaf] << sp
    end
    by_leaf.each_with_object({}) do |(leaf, sps), names|
      if sps.length > 1
        raise Error, "the classes #{sps.sort.join(' and ')} share the Ruby name #{leaf}; " \
                     "keyed by that name they would be one class"
      end
      names[sps.first] = leaf
    end
  end

  Ast = Struct.new(:files, :declared, :root, :ref, :iattr, :sattr, :arr, keyword_init: true) do
    def kind(id) = declared[id]
    def children(id)
      ref.fetch(id, {}).values.reject { |v| v < 0 } + arr.fetch(id, {}).values.flatten
    end
  end

  def self.parse_ast(raw)
    files = {}
    declared = {}
    root = nil
    ref = Hash.new { |h, k| h[k] = {} }
    iattr = Hash.new { |h, k| h[k] = {} }
    sattr = Hash.new { |h, k| h[k] = {} }
    arr = Hash.new { |h, k| h[k] = {} }
    links = []
    raw.each_line.with_index(1) do |ln, lineno|
      next if ln.strip.empty?
      f = ln.chomp.split(" ", 4)
      tag = f[0]
      AST_TAGS.include?(tag) or raise Error, "ast line #{lineno}: unknown record tag #{tag.inspect}"
      case tag
      when "SOURCE_FILE" then next
      when "FILE"
        i = Integer(f[1], 10)
        files.key?(i) and raise Error, "ast line #{lineno}: file id #{i} is declared twice"
        files[i] = f[2]
      when "ROOT"
        root.nil? or raise Error, "ast line #{lineno}: a second ROOT"
        root = Integer(f[1], 10)
      when "N"
        i = Integer(f[1], 10)
        declared.key?(i) and raise Error, "ast line #{lineno}: node #{i} is declared twice"
        declared[i] = f[2]
      else
        i = Integer(f[1], 10)
        key = f[2]
        slot = { "S" => sattr, "I" => iattr, "R" => ref, "A" => arr }[tag]
        slot[i].key?(key) and raise Error, "ast line #{lineno}: node #{i} sets #{key} twice"
        case tag
        when "S" then slot[i][key] = f[3].to_s
        when "I" then slot[i][key] = Integer(f[3], 10)
        when "R"
          v = Integer(f[3], 10)
          slot[i][key] = v
          links << [lineno, i, key, v] if v != -1
        when "A"
          vals = f[3].to_s.empty? ? [] : f[3].split(",").map { |x| Integer(x, 10) }
          slot[i][key] = vals
          vals.each { |v| links << [lineno, i, key, v] }
        end
      end
    end
    root or raise Error, "the ast face declares no ROOT"
    declared.key?(root) or raise Error, "the ast ROOT #{root} is not a declared node"
    orphan = (ref.keys + iattr.keys + sattr.keys + arr.keys).uniq.reject { |i| declared.key?(i) }
    unless orphan.empty?
      raise Error, "the ast face sets fields on #{orphan.length} undeclared node(s), " \
                   "the first being #{orphan.min}"
    end
    dangling = links.reject { |_, _, _, v| declared.key?(v) }
    unless dangling.empty?
      l, i, k, v = dangling.first
      raise Error, "ast line #{l}: node #{i}'s #{k} links to #{v}, which is no declared node " \
                   "(#{dangling.length} such link(s))"
    end
    Ast.new(files: files, declared: declared, root: root,
            ref: ref, iattr: iattr, sattr: sattr, arr: arr)
  end
end
