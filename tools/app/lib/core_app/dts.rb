# frozen_string_literal: true
#
# tools/app/lib/core_app/dts.rb -- reads a final `zephyr.dts` into a node tree
# (decision 0014 §3: the board package is generated from the DTS text of the
# configure step).
#
# The input is the DTS the Zephyr build writes to build/zephyr/zephyr.dts: one
# flattened file, comments in `/* */`, no includes, no `/delete-node/` and no
# macros -- those were resolved before it was written. What the reader admits
# is exactly that: a `/dts-v1/;` header, nodes with any number of labels,
# properties whose values are strings, cell arrays `< ... >` holding numbers
# and `&label` references, byte arrays `[ .. ]`, bare `&label` references,
# lists of those separated by commas, and boolean properties with no value.
# Anything else is an error naming the line. A reader that guessed at an
# unfamiliar construct would put a device in the board package that the
# devicetree did not describe.
require "strscan"

module CoreApp
  module Dts
    class Error < StandardError; end

    Ref = Struct.new(:label) do
      def to_s = "&#{label}"
    end
    Bytes = Struct.new(:bytes)

    class Node
      attr_reader :name, :labels, :properties, :children, :parent, :line

      def initialize(name, labels, parent, line)
        @name = name
        @labels = labels
        @parent = parent
        @line = line
        @properties = {}
        @children = []
      end

      def path
        return "/" if parent.nil?
        parent.parent.nil? ? "/#{name}" : "#{parent.path}/#{name}"
      end

      def [](prop) = @properties[prop]
      def string(prop)
        v = @properties[prop]
        v.is_a?(Array) && v.first.is_a?(String) ? v.first : nil
      end
      def strings(prop)
        v = @properties[prop]
        v.is_a?(Array) ? v.select { |x| x.is_a?(String) } : []
      end
      # The cells of a `< ... >` property, flattened across a comma list.
      def cells(prop)
        v = @properties[prop]
        return nil unless v
        v.flat_map { |x| x.is_a?(Array) ? x : [x] }
      end
      def compatible = strings("compatible")
      # `status` absent or "okay" is enabled, "disabled" is not; any other
      # value is refused by name (a final zephyr.dts holds only these two --
      # dtlib normalises the legacy "ok" -- so another value is an unknown
      # form, not a guess either way).
      def enabled?
        return true unless @properties.key?("status")
        case string("status")
        when "okay" then true
        when "disabled" then false
        else raise Error, "#{path}: status #{string('status').inspect} is neither \"okay\" nor \"disabled\""
        end
      end

      def each(&block)
        block.call(self)
        @children.each { |c| c.each(&block) }
      end

      def find(path)
        each { |n| return n if n.path == path }
        nil
      end
    end

    class Tree
      attr_reader :root, :labels

      def initialize(root)
        @root = root
        @labels = {}
        root.each { |n| n.labels.each { |l| @labels[l] = n } }
      end

      def by_label(label) = @labels[label]
      def by_path(path) = @root.find(path)
      def each(&block) = @root.each(&block)
      # The node a reference names, or an error naming where it came from.
      def resolve(ref, where)
        @labels[ref.label] or raise Error, "#{where}: &#{ref.label} names no label in the devicetree"
      end
      # Every enabled node whose compatible list includes `c`.
      def compatibles(c)
        out = []
        each { |n| out << n if n.enabled? && n.compatible.include?(c) }
        out
      end
    end

    module_function

    def parse(text)
      Parser.new(text).parse
    end

    def read(path)
      parse(File.read(path))
    end

    class Parser
      Token = Struct.new(:kind, :value, :line)

      def initialize(text)
        @tokens = tokenize(text)
        @i = 0
      end

      def parse
        expect(:header)
        expect(:slash)
        root = Node.new("/", [], nil, peek.line)
        body(root)
        expect(:semicolon)
        raise Error, "line #{peek.line}: text after the root node" unless peek.kind == :eof
        Tree.new(root)
      end

      private

      IDENT = %r{[A-Za-z0-9_,.+\-@#?]+}

      def tokenize(text)
        text = text.gsub(%r{/\*.*?\*/}m) { |c| c.gsub(/[^\n]/, " ") }.gsub(%r{//[^\n]*}, "")
        tokens = []
        line = 1
        s = StringScanner.new(text)
        until s.eos?
          if s.scan(/[ \t\r]+/) then next
          elsif s.scan(/\n/) then line += 1
          elsif s.scan(%r{/dts-v1/;}) then tokens << Token.new(:header, nil, line)
          elsif s.scan(/"((?:[^"\\]|\\.)*)"/) then tokens << Token.new(:string, unescape(s[1], line), line)
          elsif s.scan(/&\{([^}]*)\}/) then tokens << Token.new(:pathref, s[1], line)
          elsif s.scan(/&([A-Za-z0-9_]+)/) then tokens << Token.new(:ref, s[1], line)
          elsif s.scan(/[{}<>\[\];=,]/) then tokens << Token.new({ "{" => :lbrace, "}" => :rbrace, "<" => :lt, ">" => :gt, "[" => :lbracket, "]" => :rbracket, ";" => :semicolon, "=" => :eq, "," => :comma }.fetch(s.matched), nil, line)
          elsif s.scan(%r{/}) then tokens << Token.new(:slash, nil, line)
          elsif s.scan(/([A-Za-z0-9_]+):/) then tokens << Token.new(:label, s[1], line)
          elsif s.scan(IDENT) then tokens << Token.new(:ident, s.matched, line)
          else raise Error, "line #{line}: unreadable text #{s.peek(20).inspect}"
          end
        end
        tokens << Token.new(:eof, nil, line)
        tokens
      end

      ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", "0" => "\0", "\\" => "\\", "\"" => "\"" }.freeze
      def unescape(text, line)
        text.gsub(/\\(.)/) { ESCAPES.fetch(Regexp.last_match(1)) { raise Error, "line #{line}: unknown escape \\#{Regexp.last_match(1)} in a string" } }
      end

      def peek = @tokens[@i]
      def advance
        t = @tokens[@i]
        @i += 1
        t
      end

      def expect(kind)
        t = advance
        raise Error, "line #{t.line}: expected #{kind}, found #{t.kind}#{t.value ? " #{t.value.inspect}" : ''}" unless t.kind == kind
        t
      end

      # `{ (property | node)* }` after the node's name.
      def body(node)
        expect(:lbrace)
        loop do
          t = peek
          case t.kind
          when :rbrace
            advance
            return
          when :label
            labels = []
            labels << advance.value while peek.kind == :label
            name = expect(:ident)
            child = Node.new(name.value, labels, node, name.line)
            body(child)
            expect(:semicolon)
            node.children << child
          when :ident
            advance
            case peek.kind
            when :lbrace
              child = Node.new(t.value, [], node, t.line)
              body(child)
              expect(:semicolon)
              node.children << child
            when :semicolon
              advance
              node.properties[t.value] = true
            when :eq
              advance
              node.properties[t.value] = values
              expect(:semicolon)
            else
              raise Error, "line #{peek.line}: after #{t.value.inspect}, expected `{`, `=` or `;`"
            end
          else
            raise Error, "line #{t.line}: expected a property or a node, found #{t.kind}#{t.value ? " #{t.value.inspect}" : ''}"
          end
        end
      end

      def values
        vs = [value]
        while peek.kind == :comma
          advance
          vs << value
        end
        vs
      end

      def value
        t = peek
        case t.kind
        when :string then advance.value
        when :ref then Ref.new(advance.value)
        when :pathref then advance.value
        when :lt
          advance
          cells = []
          until peek.kind == :gt
            c = advance
            case c.kind
            when :ident then cells << integer(c)
            when :ref then cells << Ref.new(c.value)
            else raise Error, "line #{c.line}: a cell is a number or a &reference, not #{c.kind}"
            end
          end
          advance
          cells
        when :lbracket
          advance
          bytes = []
          until peek.kind == :rbracket
            c = expect(:ident)
            raise Error, "line #{c.line}: a byte is two hex digits, not #{c.value.inspect}" unless c.value.match?(/\A[0-9a-fA-F]{2}\z/)
            bytes << c.value.to_i(16)
          end
          advance
          Bytes.new(bytes)
        else
          raise Error, "line #{t.line}: a value is a string, < cells >, [ bytes ] or a &reference, not #{t.kind}"
        end
      end

      def integer(t)
        case t.value
        when /\A0[xX][0-9a-fA-F]+\z/ then t.value.to_i(16)
        when /\A[0-9]+\z/ then t.value.to_i(10)
        else raise Error, "line #{t.line}: #{t.value.inspect} is not a number"
        end
      end
    end
  end
end
