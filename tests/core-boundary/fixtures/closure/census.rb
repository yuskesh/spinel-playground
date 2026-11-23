# frozen_string_literal: true
#
# A CENSUS of the Full DOOM tree against the checked subset, for
# docs/core/doom-closure-gaps.md.
#
# For every `def` in examples/doom/lib/doom/, this counts which of the
# constructs the subset refuses appear in its body OR its parameter list. The
# point is to put a number on "what is left", rather than to argue about it
# from a reading.
#
# `def` is not the same as "every method". `attr_reader` and its relatives
# define methods too, and there are more of them than one would guess, so they
# are counted separately rather than quietly left out of the denominator.
#
# WHAT IT DOES NOT SAY. A method with none of these constructs is not thereby
# admissible: it may still call a method this does not follow, use an operator
# with no contract, or need a shape the ABI has no way to declare. So the count
# of clean methods is an UPPER BOUND on what could be extracted without a
# subset change, and the per-construct counts are a LOWER BOUND on what is
# blocked -- each is the honest direction for its purpose.
#
# usage: census.rb <repo-root>

require "prism"

root = ARGV[0] or abort("census: the repository root is required")

# Each node kind that is refused, mapped to the name the gap record uses. The
# categories are the ones constructs.tsv probes, so the two can be read
# together.
KINDS = {
  "AndNode" => "and-or", "OrNode" => "and-or",
  "UnlessNode" => "no-else-branch", "UntilNode" => "until",
  "CaseNode" => "case", "BreakNode" => "break-next", "NextNode" => "break-next",
  "InstanceVariableReadNode" => "instance-state",
  "InstanceVariableWriteNode" => "instance-state",
  "InstanceVariableOperatorWriteNode" => "instance-state",
  "ArrayNode" => "allocation", "StringNode" => "allocation", "HashNode" => "allocation",
  "FloatNode" => "float", "RangeNode" => "range",
  "IndexOperatorWriteNode" => "element-op-assign",
  "RescueNode" => "exceptions",
  "YieldNode" => "blocks",
  "MultiWriteNode" => "multiple-assignment",
}.freeze

# EVERY OTHER node kind this tree puts in a method, listed so the rule is
# "consume it or refuse it" rather than "notice the ones I thought of". A kind
# in neither table is reported as unclassified and the lane fails on it: the
# alternative is a census that quietly stops counting when the tree changes.
ALLOWED = %w[
  AndNode ArgumentsNode ArrayNode AssocNode BackReferenceReadNode BeginNode
  BlockArgumentNode BlockNode BlockParameterNode BlockParametersNode BreakNode
  CallAndWriteNode CallNode CallOperatorWriteNode CallOrWriteNode CaseNode
  ClassVariableReadNode ClassVariableWriteNode ConstantPathNode
  ConstantPathWriteNode ConstantReadNode ConstantWriteNode ElseNode
  EmbeddedStatementsNode EmbeddedVariableNode FalseNode FloatNode ForwardingArgumentsNode
  GlobalVariableReadNode GlobalVariableWriteNode HashNode IfNode ImplicitNode
  IndexAndWriteNode IndexOperatorWriteNode IndexOrWriteNode InstanceVariableAndWriteNode
  InstanceVariableOperatorWriteNode InstanceVariableOrWriteNode
  InstanceVariableReadNode InstanceVariableWriteNode IntegerNode
  InterpolatedStringNode InterpolatedSymbolNode KeywordHashNode
  KeywordRestParameterNode LocalVariableAndWriteNode LocalVariableOperatorWriteNode
  LocalVariableOrWriteNode LocalVariableReadNode LocalVariableTargetNode
  LocalVariableWriteNode MultiTargetNode MultiWriteNode NextNode NilNode
  OptionalParameterNode OrNode ParametersNode ParenthesesNode RangeNode
  RequiredKeywordParameterNode RequiredParameterNode RescueNode RestParameterNode
  ReturnNode SelfNode SourceFileNode SplatNode StatementsNode StringNode
  SymbolNode TrueNode UnlessNode UntilNode WhenNode WhileNode YieldNode
].freeze

def walk(node, found, kinds)
  return unless node
  k = node.class.name.split("::").last
  kinds[k] = true
  found[KINDS[k]] = true if KINDS[k]
  # An `if` with no else leaves one path without a value, which is the same
  # refusal `unless` gets and is far commoner in this tree.
  if k == "IfNode"
    subsequent = node.respond_to?(:subsequent) ? node.subsequent : node.consequent
    found["no-else-branch"] = true if subsequent.nil?
  end
  if k == "CallNode"
    found["blocks"] = true if node.block
    found["raise"] = true if node.name == :raise
  end
  node.compact_child_nodes.each { |c| walk(c, found, kinds) }
end

files = Dir[File.join(root, "examples", "doom", "lib", "doom", "*.rb")].sort
abort("census: no Full sources at #{root}") if files.empty?

total = 0
attrs = 0
attr_sites = 0
clean = []
tally = Hash.new(0)
kinds = {}
files.each do |path|
  stack = [Prism.parse_file(path).value]
  until stack.empty?
    n = stack.pop
    # `attr_reader :a, :b` defines two methods and no `def`. They are all
    # instance-state readers, so they cannot be entries; counting them
    # separately keeps them out of the `def` figures without dropping them.
    if n.is_a?(Prism::CallNode) && n.receiver.nil? &&
       %i[attr_reader attr_writer attr_accessor].include?(n.name) && n.arguments
      per = n.name == :attr_accessor ? 2 : 1
      attrs += n.arguments.arguments.length * per
      # The CALL SITES as well as the methods they define. The record quotes
      # both, and a figure nothing counts is one a reader has to take on
      # trust: this one had been counted by hand.
      attr_sites += 1
    end
    if n.class.name.end_with?("DefNode")
      total += 1
      found = {}
      # The parameter list as well as the body: a default value or a keyword
      # parameter holds expressions too, and a census that read only the body
      # would not see them.
      walk(n.parameters, found, kinds)
      walk(n.body, found, kinds)
      if found.empty?
        clean << "#{File.basename(path)}##{n.name}"
      else
        found.each_key { |r| tally[r] += 1 }
      end
    end
    stack.concat(n.compact_child_nodes)
  end
end

unclassified = kinds.keys.reject { |k| KINDS.key?(k) || ALLOWED.include?(k) }.sort

puts "files\t#{files.length}"
puts "defs\t#{total}"
puts "attr_methods\t#{attrs}"
puts "attr_sites\t#{attr_sites}"
puts "clean\t#{clean.length}"
tally.sort_by { |k, v| [-v, k] }.each { |k, v| puts "blocked\t#{k}\t#{v}" }
unclassified.each { |k| puts "unclassified\t#{k}" }
# The calibration sample, named rather than described: the entries this
# repository actually extracted, and which side of the census each fell on.
%w[to_i32 bam mul cdiv div].each do |m|
  puts "calibrate\tfixed.rb##{m}\t#{clean.include?("fixed.rb##{m}") ? 'clean' : 'blocked'}"
end
puts "calibrate\tbytes.rb#u8\t#{clean.include?('bytes.rb#u8') ? 'clean' : 'blocked'}"
