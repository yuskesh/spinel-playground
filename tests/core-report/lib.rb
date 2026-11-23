# frozen_string_literal: true
#
# tests/core-report/lib.rb -- shared by the core-report checks.
#
# Two things the kernel also does, written again here on purpose, from the
# document rather than from the C++:
#
#   CoreReport::Schema  a validator for the JSON Schema subset the report
#                       schema uses. It refuses a keyword it does not know, so
#                       the schema cannot quietly rely on something nothing
#                       checks.
#   CoreReport::Expr    an evaluator for the bound expression grammar, so a
#                       reported bound can be compared with what a CRuby run
#                       of the same source counted.
#
# Ruby's standard library only; no gem.

require "json"

module CoreReport
  # JSON this harness writes ITSELF, byte for byte, because the golden reports
  # are compared as bytes across hosts and `JSON.pretty_generate` is not a
  # stable target: json 2.7.2, which Debian's ruby 3.3.8 ships, writes a
  # newline inside an empty array or object, and json 2.8.0 and later write
  # `[]` and `{}`. Measured on Debian: the three goldens differed from the
  # macOS ones on empty-collection lines alone, 8, 8 and 28 of them.
  #
  # The contract is written down in docs/core/core-report.md and pinned by
  # tests/core-report/fixtures/canonical.json, which renders every shape whose
  # rendering has moved between versions. Nothing here delegates to the json
  # library, so a library change fails that fixture rather than surfacing as a
  # mystery diff in a golden on the other host.
  module Json
    module_function

    # The canonical BYTES of `value`, ending in exactly one newline. Binary,
    # not text: non-ASCII is written as itself, so byte identity across hosts
    # must not depend on either host's locale or default external encoding.
    # Every writer of these bytes writes them in binary, and every comparison
    # reads them in binary.
    def dump(value)
      (+"" << emit(value, 0) << "\n").b
    end

    def emit(value, depth)
      case value
      when Hash then collection(value.map { |k, v| [string(key(k)), v] }, depth, "{", "}")
      when Array then collection(value.map { |v| [nil, v] }, depth, "[", "]")
      when String then string(value)
      when Integer then value.to_s
      when true, false then value.to_s
      when nil then "null"
      when Float
        # The schema admits no float, so there is no canonical rendering to
        # choose. A future one is a decision, not something to discover from
        # whatever a library prints.
        raise ArgumentError, "canonical JSON: no rendering is defined for the float #{value}"
      else
        raise ArgumentError, "canonical JSON: cannot write a #{value.class}"
      end
    end

    def key(k)
      return k if k.is_a?(String)
      raise ArgumentError, "canonical JSON: a key must be a string, got #{k.class}"
    end

    # Empty collections are `[]` and `{}`; a non-empty one puts each item on
    # its own line, indented two spaces per level, with the closing bracket at
    # the opening line's indentation.
    #
    # KEYS KEEP THE ORDER THEY WERE INSERTED IN, AND ARE NEVER SORTED. The
    # order is the KERNEL's: the report is read top to bottom as the kernel
    # wrote it, and this only passes that order through. Sorting them here to
    # be helpful would move every committed golden and would say that the
    # order is the harness's to choose, which it is not.
    def collection(items, depth, open, close)
      return open + close if items.empty?
      inner = "  " * (depth + 1)
      body = items.map do |k, v|
        inner + (k ? "#{k}: " : "") + emit(v, depth + 1)
      end
      open + "\n" + body.join(",\n") + "\n" + ("  " * depth) + close
    end

    # `"` and `\` are escaped, the control characters below 0x20 use their
    # short form where JSON defines one and `\u00XX` otherwise, and every
    # other character is written as itself: text stays UTF-8 and non-ASCII is
    # never escaped. DEL and U+2028 are ordinary characters here, as they are
    # in JSON.
    # Every shape whose rendering has moved between json versions, plus the
    # ones this emitter decides itself. tests/core-report/fixtures/canonical.json
    # is this value, and the suite compares it byte for byte.
    # The agreed union of both hosts' probes. A float is deliberately NOT here:
    # the emitter refuses one, so a float among these bytes would contradict
    # the contract. It is covered by a refusal assertion in check.rb instead.
    def sample
      {
        # containers
        "empty_array" => [],
        "empty_object" => {},
        "one_element_array" => [1],
        "one_element_object" => { "only" => 1 },
        "nested_in_array" => [[], {}, { "b" => [] }],
        "nested_in_object" => { "b" => [], "c" => {}, "d" => { "e" => {} } },
        # strings
        "non_ascii_bmp" => "ý あ",
        # A non-BMP character is a surrogate pair in UTF-16, and whether an
        # emitter writes it raw or as two escapes is exactly the kind of thing
        # a json version changes.
        "non_bmp" => "\u{1F600}",
        "control" => " ",
        "quote_and_backslash" => "q \" b \\",
        "newline_and_tab" => "n \n t \t",
        "del" => "",
        # Legal to escape as `\/`, and some emitters do; measured raw on
        # 2.12.2, so raw is what this pins.
        "solidus" => "a/b",
        "empty_string" => "",
        # numbers
        "int64_max" => 9_223_372_036_854_775_807,
        "beyond_int64" => 18_446_744_073_709_551_616,
        "int64_min" => -9_223_372_036_854_775_808,
        "minus_one" => -1,
        "zero" => 0,
        # literals, in one object
        "literals" => { "t" => true, "f" => false, "n" => nil },
        # structure: a sort would put "a" first
        "key_order" => { "z" => 1, "a" => 2 },
        # an empty string as a KEY, at both levels
        "" => { "" => "", "with space" => 0 }
      }
    end

    # The SAME value rendered the way json 2.7.2 renders it, which is what
    # Debian's ruby 3.3.8 ships and what the gate refused: an empty array with
    # a blank line between its brackets, an empty object with a newline and an
    # indent. It exists to be REJECTED -- tests/core-report/fixtures/
    # canonical-rejected.json is kept so the rejection is demonstrated by a
    # file in the branch rather than by a story about a run that once happened.
    def dump_legacy_empties(value, depth = 0)
      case value
      when Hash
        return "{\n" + "  " * depth + "}" if value.empty?
        inner = "  " * (depth + 1)
        "{\n" + value.map { |k, v|
          inner + string(key(k)) + ": " + dump_legacy_empties(v, depth + 1)
        }.join(",\n") + "\n" + "  " * depth + "}"
      when Array
        return "[\n\n" + "  " * depth + "]" if value.empty?
        inner = "  " * (depth + 1)
        "[\n" + value.map { |v| inner + dump_legacy_empties(v, depth + 1) }.join(",\n") +
          "\n" + "  " * depth + "]"
      else
        emit(value, depth)
      end
    end

    SHORT = { "\b" => "\\b", "\t" => "\\t", "\n" => "\\n", "\f" => "\\f", "\r" => "\\r" }.freeze
    def string(text)
      # Refused rather than written out: bytes that are not valid UTF-8 are
      # not JSON, and emitting them would produce a file whose meaning depends
      # on who reads it.
      unless text.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise ArgumentError, "canonical JSON: #{text.inspect} is not valid UTF-8"
      end
      out = +'"'
      text.each_char do |c|
        out << case c
               when '"' then '\\"'
               when "\\" then "\\\\"
               when *SHORT.keys then SHORT[c]
               else c.ord < 0x20 ? format("\\u%04x", c.ord) : c
               end
      end
      out << '"'
    end
  end

  class Schema
    ANNOTATIONS = %w[$schema $id title description $defs].freeze
    KEYWORDS = %w[$ref type const enum pattern minimum minItems maxItems required
                  properties additionalProperties items oneOf].freeze

    def initialize(root)
      @root = root
    end

    # Every error, as "path: message". Empty means valid.
    def validate(instance, schema = @root, path = "$")
      errors = []
      check(instance, schema, path, errors)
      errors
    end

    private

    def resolve(ref)
      raise ArgumentError, "unsupported $ref #{ref}" unless ref.start_with?("#/")
      ref.delete_prefix("#/").split("/").reduce(@root) do |node, key|
        node.fetch(key) { raise ArgumentError, "unresolved $ref #{ref}" }
      end
    end

    def type_ok?(value, type)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "number" then value.is_a?(Numeric)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else raise ArgumentError, "unsupported type #{type}"
      end
    end

    def check(value, schema, path, errors)
      return if schema == true || schema == {}
      raise ArgumentError, "schema at #{path} is not an object" unless schema.is_a?(Hash)

      schema.each_key do |k|
        next if ANNOTATIONS.include?(k) || KEYWORDS.include?(k)
        raise ArgumentError, "unsupported schema keyword #{k} at #{path}"
      end

      if schema.key?("$ref")
        check(value, resolve(schema["$ref"]), path, errors)
      end
      if schema.key?("type")
        types = Array(schema["type"])
        unless types.any? { |t| type_ok?(value, t) }
          errors << "#{path}: expected #{types.join(' or ')}, got #{value.inspect[0, 60]}"
          return
        end
      end
      if schema.key?("const") && value != schema["const"]
        errors << "#{path}: expected #{schema['const'].inspect}, got #{value.inspect[0, 60]}"
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        errors << "#{path}: #{value.inspect[0, 60]} is not one of #{schema['enum'].join(', ')}"
      end
      if schema.key?("pattern") && value.is_a?(String) && value !~ Regexp.new(schema["pattern"])
        errors << "#{path}: #{value.inspect[0, 60]} does not match #{schema['pattern']}"
      end
      if schema.key?("minimum") && value.is_a?(Numeric) && value < schema["minimum"]
        errors << "#{path}: #{value} is below #{schema['minimum']}"
      end
      if value.is_a?(Array)
        if schema.key?("minItems") && value.length < schema["minItems"]
          errors << "#{path}: #{value.length} item(s), fewer than #{schema['minItems']}"
        end
        if schema.key?("maxItems") && value.length > schema["maxItems"]
          errors << "#{path}: #{value.length} item(s), more than #{schema['maxItems']}"
        end
        if schema.key?("items")
          value.each_with_index { |v, i| check(v, schema["items"], "#{path}[#{i}]", errors) }
        end
      end
      if value.is_a?(Hash)
        (schema["required"] || []).each do |k|
          errors << "#{path}: missing required #{k}" unless value.key?(k)
        end
        props = schema["properties"] || {}
        value.each do |k, v|
          if props.key?(k)
            check(v, props[k], "#{path}.#{k}", errors)
          elsif schema.key?("additionalProperties")
            extra = schema["additionalProperties"]
            if extra == false
              errors << "#{path}: unexpected key #{k}"
            else
              check(v, extra, "#{path}.#{k}", errors)
            end
          end
        end
      end
      if schema.key?("oneOf")
        matches = schema["oneOf"].map { |s| validate(value, s, path) }
        count = matches.count(&:empty?)
        if count != 1
          detail = count.zero? ? matches.min_by(&:length).first(3).join("; ") : "#{count} alternatives"
          errors << "#{path}: matches #{count} of #{schema['oneOf'].length} alternatives (#{detail})"
        end
      end
    end
  end

  # The bound grammar of docs/core/core-report.md:
  #
  #   expr    := term (("+" | "-") term)*
  #   term    := unary ("*" unary)*
  #   unary   := "-" unary | primary
  #   primary := integer | name | name "(" expr ("," expr)* ")" | "(" expr ")"
  #
  # over mathematical integers, with max(a, b), ceil_div(a, c) for a >= 0 and
  # c > 0, floor_div(a, b) and floor_mod(a, b) as Ruby's Integer / and %.
  class Expr
    FUNCTIONS = {
      "max" => ->(a, b) { [a, b].max },
      "ceil_div" => lambda { |a, c|
        raise ArgumentError, "ceil_div(#{a}, #{c}) outside its domain" if a.negative? || c <= 0
        (a + c - 1) / c
      },
      "floor_div" => ->(a, b) { a / b },
      "floor_mod" => ->(a, b) { a % b }
    }.freeze

    def self.evaluate(text, env)
      new(text, env).evaluate
    end

    def initialize(text, env)
      @tokens = text.scan(/\d+|[A-Za-z_][A-Za-z0-9_]*|[-+*(),]|\S/)
      @env = env
      @pos = 0
    end

    def evaluate
      value = expr
      raise ArgumentError, "trailing #{@tokens[@pos]}" if @pos < @tokens.length
      value
    end

    private

    def peek = @tokens[@pos]

    def take(expected = nil)
      tok = @tokens[@pos]
      raise ArgumentError, "expected #{expected}, got #{tok.inspect}" if expected && tok != expected
      raise ArgumentError, "unexpected end" if tok.nil?
      @pos += 1
      tok
    end

    def expr
      value = term
      while %w[+ -].include?(peek)
        op = take
        rhs = term
        value = op == "+" ? value + rhs : value - rhs
      end
      value
    end

    def term
      value = unary
      while peek == "*"
        take
        value *= unary
      end
      value
    end

    def unary
      if peek == "-"
        take
        return -unary
      end
      primary
    end

    def primary
      tok = take
      return tok.to_i if tok.match?(/\A\d+\z/)
      if tok == "("
        value = expr
        take(")")
        return value
      end
      raise ArgumentError, "unexpected #{tok.inspect}" unless tok.match?(/\A[A-Za-z_]/)
      if peek == "("
        fn = FUNCTIONS.fetch(tok) { raise ArgumentError, "unknown function #{tok}" }
        take("(")
        args = [expr]
        while peek == ","
          take
          args << expr
        end
        take(")")
        raise ArgumentError, "#{tok} takes #{fn.arity} arguments" if args.length != fn.arity
        return fn.call(*args)
      end
      @env.fetch(tok) { raise ArgumentError, "no value for #{tok}" }
    end
  end

  # tests/core-report/expect.tsv, as rows of hashes.
  def self.expectations(path)
    File.readlines(path, chomp: true).reject { |l| l.start_with?("#") || l.strip.empty? }.map do |l|
      f = l.split("\t", -1)
      raise ArgumentError, "#{path}: #{f.length} columns in #{l.inspect}" unless f.length == 7
      %w[entry subject verdict value extra tight counter].zip(f).to_h
    end
  end

  # `a=1;b=x` into {"a"=>"1","b"=>"x"}; `-` is none.
  def self.extras(text)
    return {} if text == "-"
    text.split(";").to_h { |pair| pair.split("=", 2) }
  end
end
