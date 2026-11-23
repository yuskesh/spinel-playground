# frozen_string_literal: true
# Decision 0026 steps 1 and 5: the freestanding subset refusal tables are
# hand-maintained, and this check holds them to pin.tsv: the owned table
# (SubsetRefusals.cpp: node kinds with their CORE rule, call names) and the
# inherited list (SubsetTables.cpp: node kinds), taken together. It reads the
# C++ source; nothing is built.
require 'digest'

root = File.expand_path('../..', __dir__)
REFUSALS = 'tools/mlir/native/lib/Core/SubsetRefusals.cpp'
INHERITED = 'tools/mlir/native/lib/Frontend/Scalar/SubsetTables.cpp'
PIN = 'tests/subset-tables/pin.tsv'
# Each table: the file it is in, its function, its value type, the pin table
# it belongs to, and whether its entries carry the CORE rule.
TABLES = [
  { file: REFUSALS, fn: 'subsetRefusalNodes', type: 'NodeRefusal', table: 'node', rule: true },
  { file: INHERITED, fn: 'fsInheritedNodes', type: 'std::string', table: 'node', rule: false },
  { file: REFUSALS, fn: 'subsetRefusalCalls', type: 'std::string', table: 'call', rule: false }
].freeze
RULES = %w[HeapOperation Refusal].freeze

Failure = Struct.new(:name, :message)

# The initializer of `static const std::map<std::string, TYPE> t = { ... };`
# in the function named fn: {"KEY", "REASON"} entries, or {"KEY", {RULE,
# "REASON"}} where rule is set, and adjacent string literals concatenate.
# Anything else in the list is a parse failure, so an entry written in a form
# this reader does not know is never skipped. Returns [key, reason, rule, line].
def read_table(text, spec)
  fn = spec[:fn]
  head = /&#{fn}\(\)\s*\{\s*static const std::map<std::string, #{Regexp.escape(spec[:type])}> t = \{/.match(text)
  raise ArgumentError, "#{fn}(): its `t = {` initializer was not found" unless head

  pos = head.end(0)
  tokens = []
  loop do
    m = %r{\G(?:\s+|//[^\n]*|/\*.*?\*/)*}m.match(text, pos)
    pos = m.end(0)
    raise ArgumentError, "#{fn}(): the initializer does not end" if pos >= text.size

    line = text[0, pos].count("\n") + 1
    if (s = /\G"((?:[^"\\\n]|\\.)*)"/.match(text, pos))
      body = s[1].gsub(/\\(.)/) do
        { '\\' => '\\', '"' => '"', "'" => "'", 'n' => "\n", 't' => "\t" }.fetch(Regexp.last_match(1)) do
          raise ArgumentError, "#{fn}(): line #{line}: escape \\#{Regexp.last_match(1)} is not read here"
        end
      end
      tokens << [:str, body, line]
      pos = s.end(0)
    elsif (s = /\G[A-Za-z_]\w*/.match(text, pos))
      tokens << [:ident, s[0], line]
      pos = s.end(0)
    elsif '{},;'.include?(text[pos])
      tokens << [text[pos].to_sym, nil, line]
      pos += 1
      break if tokens[-1][0] == :';'
    else
      raise ArgumentError, "#{fn}(): line #{line}: unexpected #{text[pos, 20].inspect}"
    end
  end

  entries = []
  i = 0
  expect = lambda do |kind|
    t = tokens[i]
    raise ArgumentError, "#{fn}(): line #{t[2]}: expected #{kind}, found #{t[0]}" unless t[0] == kind

    i += 1
    t
  end
  strings = lambda do
    expect.call(:str)
    first = i - 1
    i += 1 while tokens[i][0] == :str
    tokens[first...i].map { |t| t[1] }.join
  end
  until tokens[i][0] == :'}'
    line = expect.call(:'{')[2]
    key = strings.call
    expect.call(:',')
    rule = nil
    if spec[:rule]
      expect.call(:'{')
      rule = expect.call(:ident)[1]
      raise ArgumentError, "#{fn}(): line #{line}: rule #{rule} is not one of #{RULES.join(', ')}" unless RULES.include?(rule)

      expect.call(:',')
    end
    reason = strings.call
    expect.call(:'}') if spec[:rule]
    expect.call(:'}')
    entries << [key, reason, rule, line]
    break unless tokens[i][0] == :','

    i += 1
  end
  expect.call(:'}')
  expect.call(:';')
  entries
end

def read_pin(text)
  pin = { 'node' => [], 'call' => [], 'heap' => [], 'digest' => nil }
  text.each_line.with_index(1) do |l, n|
    next if l.start_with?('#') || l.strip.empty?

    f = l.chomp.split("\t", -1)
    raise ArgumentError, "#{PIN}:#{n}: expected two tab-separated fields" unless f.size == 2

    case f[0]
    when 'node', 'call', 'heap' then pin[f[0]] << f[1]
    when 'reasons-sha256' then pin['digest'] = f[1]
    else raise ArgumentError, "#{PIN}:#{n}: unknown row #{f[0].inspect}"
    end
  end
  raise ArgumentError, "#{PIN}: no reasons-sha256 row" unless pin['digest']

  pin
end

# The reasons' digest: one line "TABLE<TAB>KEY<TAB>REASON<LF>" per entry, the
# node table then the call table, each in byte order of its keys (std::map's).
def digest(tables)
  Digest::SHA256.hexdigest(%w[node call].flat_map do |t|
    tables[t].keys.sort.map { |k| "#{t}\t#{k}\t#{tables[t][k]}\n" }
  end.join)
end

def keys_failure(name, what, have, pinned)
  missing = pinned - have
  extra = have - pinned
  return nil if missing.empty? && extra.empty? && pinned.uniq.size == pinned.size

  Failure.new(name, "#{what}: " \
    "#{extra.empty? ? '' : "not pinned #{extra.map(&:inspect).join(', ')}; "}" \
    "#{missing.empty? ? '' : "pinned but absent #{missing.map(&:inspect).join(', ')}; "}" \
    "#{have.size} in the source, #{pinned.size} in the pin")
end

# Every failure, by name: parse, duplicate-key, in-both-files, node-keys,
# call-keys, heap-rows, reason-digest. texts maps a file to its text.
# Returns [failures, tables].
def judge(texts, pin)
  failures = []
  tables = { 'node' => {}, 'call' => {} }
  where = {}
  heap = []
  parsed = 0
  TABLES.each do |spec|
    entries = begin
      read_table(texts.fetch(spec[:file]), spec)
    rescue ArgumentError => e
      failures << Failure.new('parse', "#{File.basename(spec[:file])}: #{e.message}")
      next
    end
    parsed += 1
    seen = {}
    entries.each do |key, reason, rule, line|
      at = "#{File.basename(spec[:file])}:#{line}"
      if seen.key?(key)
        # std::map keeps the first of two equal keys and drops the second.
        failures << Failure.new('duplicate-key', "#{spec[:fn]}(): #{key.inspect} again at #{at}")
        next
      end
      seen[key] = true
      if tables[spec[:table]].key?(key)
        # Both lookups would answer; the walk reads the owned table first.
        failures << Failure.new('in-both-files', "#{key.inspect} at #{where[[spec[:table], key]]} and at #{at}")
        next
      end
      tables[spec[:table]][key] = reason
      where[[spec[:table], key]] = at
      heap << key if rule == 'HeapOperation'
    end
  end
  return [failures, tables] unless parsed == TABLES.size

  [['node', 'the node kinds of both files'], ['call', 'subsetRefusalCalls()']].each do |t, what|
    f = keys_failure("#{t}-keys", what, tables[t].keys, pin[t]) and failures << f
  end
  f = keys_failure('heap-rows', 'the HeapOperation rows of subsetRefusalNodes()', heap, pin['heap']) and failures << f
  if (d = digest(tables)) != pin['digest']
    failures << Failure.new('reason-digest', "sha256 #{d}, pinned #{pin['digest']}")
  end
  [failures, tables]
end

texts = [REFUSALS, INHERITED].to_h { |f| [f, File.read(File.join(root, f))] }
pin = begin
  read_pin(File.read(File.join(root, PIN)))
rescue ArgumentError => e
  abort "FAIL pin: #{e.message}"
end
checks = 0

failures, tables = judge(texts, pin)
unless failures.empty?
  failures.each { |f| warn "FAIL #{f.name}: #{f.message}" }
  abort "subset-tables: #{REFUSALS} and #{INHERITED} do not match #{PIN}"
end
%w[node call].each do |t|
  checks += 1
  puts "  pass #{t}-keys: #{tables[t].size} #{t == 'node' ? 'node kinds' : 'call names'}, as pinned"
end
checks += 1
puts "  pass heap-rows: #{pin['heap'].size} node kinds marked HeapOperation, as pinned"
checks += 1
puts "  pass reason-digest: #{pin['digest']}"

# Planted controls: each change to the source text must fail by its name, and
# only by the names listed. A control is [what, file, from, to, names,
# mentioned], or with `to` a lambda over both texts for one that edits two
# files. names empty: the planted text must pass.
inherited_class = "      {\"ClassNode\",\n       \"a `class` definition\"},\n"
[
  ['a changed node key', REFUSALS, '{"XStringNode",', '{"XStringNodeX",', %w[node-keys reason-digest], 'XStringNodeX'],
  ['a changed call key', REFUSALS, '{"map",', '{"mapX",', %w[call-keys reason-digest], 'mapX'],
  ['a changed reason string', REFUSALS, '"a Regexp"', '"a Regexp."', %w[reason-digest], nil],
  # The planted SelfNode row comes first and is kept, with LambdaNode's rule
  # and reason, so LambdaNode leaves the keys and SelfNode joins the heap rows.
  ['a duplicated key', REFUSALS, '{"LambdaNode",', '{"SelfNode",', %w[duplicate-key node-keys heap-rows reason-digest], 'SelfNode'],
  ['a changed CORE rule', REFUSALS, '{HeapOperation, "a Regexp"}', '{Refusal, "a Regexp"}', %w[heap-rows], 'RegularExpressionNode'],
  ['a key in both files', INHERITED, inherited_class,
   "#{inherited_class}      {\"SelfNode\",\n       \"`self`\"},\n", %w[in-both-files], 'SelfNode'],
  ['an inherited key removed: the pin covers both files', INHERITED, "      {\"EnsureNode\",\n       \"an `ensure`\"},\n", '',
   %w[node-keys reason-digest], 'EnsureNode'],
  # Which file holds a key is coverage.tsv's to decide: tests/subset/map.sh
  # fails this move by name (wrong side). The pin, over both files, holds.
  ['a key moved between the files: the pin over the union still holds', nil, nil,
   lambda do |t|
     t.merge(INHERITED => t[INHERITED].sub(inherited_class, ''),
             REFUSALS => t[REFUSALS].sub("      {\"DefNode\",",
                                         "      {\"ClassNode\",\n       {Refusal, \"a `class` definition\"}},\n      {\"DefNode\","))
   end, [], nil]
].each do |what, file, from, to, names, mentioned|
  planted = to.is_a?(Proc) ? to.call(texts) : texts.merge(file => texts[file].sub(from, to))
  abort "FAIL control #{what}: the control plants nothing" if planted == texts

  got, = judge(planted, pin)
  ok = got.map(&:name).sort == names.sort &&
       (mentioned.nil? || got.any? { |f| f.name == names[0] && f.message.include?(mentioned.inspect) })
  abort "FAIL control #{what}: expected #{names.empty? ? 'a pass' : names.join(', ')}, got\n" +
        got.map { |f| "  #{f.name}: #{f.message}" }.join("\n") unless ok
  checks += 1
  puts "  pass control #{what}: #{names.empty? ? 'passes' : "fails by #{names.join(', ')}"}"
end

puts "subset-tables: #{checks} checked, #{checks} pass, 0 fail"
