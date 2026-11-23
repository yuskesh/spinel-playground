//===- SubsetRefusals.cpp - the source constructs the subsets refuse -------===//
//
// Hand-maintained (SubsetRefusals.h says what the table means). The entries
// came from SubsetTables.cpp in decision 0026 step 5, which kept the six that
// no input reaches; their origin is recorded there.
//
// tests/subset-tables/check.rb pins the key sets, the CORE heap-operation
// rows and a digest of the reasons of both files together in
// tests/subset-tables/pin.tsv: change the pin in the same commit.
//
//===----------------------------------------------------------------------===//

#include "spinel-mlir/Core/SubsetRefusals.h"

namespace spinel_mlir::core {
namespace {
constexpr CoreRule HeapOperation = CoreRule::HeapOperation;
constexpr CoreRule Refusal = CoreRule::Refusal;
} // namespace

const std::map<std::string, NodeRefusal> &subsetRefusalNodes() {
  static const std::map<std::string, NodeRefusal> t = {
      {"StringNode",
       {HeapOperation, "a String literal (every Spinel string is heap-allocated and GC-tracked -- spinel_rt.h's sp_str_* -- and freestanding has no heap)"}},
      {"InterpolatedStringNode",
       {HeapOperation, "a string interpolation (it builds a new String at run time)"}},
      {"XStringNode",
       {Refusal, "a backtick command"}},
      {"ArrayNode",
       {HeapOperation, "an Array literal (sp_ary_new allocates)"}},
      {"HashNode",
       {HeapOperation, "a Hash literal (sp_hash_new allocates)"}},
      {"KeywordHashNode",
       {Refusal, "keyword arguments (they become a Hash)"}},
      {"SymbolNode",
       {Refusal, "a Symbol literal"}},
      {"InterpolatedSymbolNode",
       {Refusal, "an interpolated Symbol"}},
      {"RangeNode",
       {HeapOperation, "a Range (it is an object)"}},
      {"RegularExpressionNode",
       {HeapOperation, "a Regexp"}},
      {"BlockNode",
       {Refusal, "a block other than a literal block on `times`, `upto`, `downto`, `each` or `each_with_index` (decision 0041)"}},
      {"LambdaNode",
       {HeapOperation, "a lambda"}},
      {"BlockArgumentNode",
       {Refusal, "a block argument"}},
      {"DefNode",
       {Refusal, "a nested `def`"}},
      {"InstanceVariableReadNode",
       {Refusal, "an instance variable (there is no `self` to hold it)"}},
      {"InstanceVariableWriteNode",
       {Refusal, "an instance variable assignment"}},
      {"GlobalVariableReadNode",
       {Refusal, "a global variable"}},
      {"GlobalVariableWriteNode",
       {Refusal, "a global variable assignment"}},
      {"ConstantReadNode",
       {Refusal, "a constant (constant lookup is a runtime operation)"}},
      {"ConstantPathNode",
       {Refusal, "a constant path (`A::B`); the application lane resolves one level, "
                 "`Mod::NAME`, against the modules of its own source (0014 D5)"}},
      {"BeginNode",
       {Refusal, "a `begin`/`rescue` (exceptions need a setjmp stack and an Exception object)"}},
      {"YieldNode",
       {Refusal, "a `yield`"}},
      {"ForNode",
       {Refusal, "a `for` loop (it calls #each with a block)"}},
      {"CaseNode",
       {Refusal, "a `case` (=== dispatch)"}},
      {"SelfNode",
       {Refusal, "`self`"}},
      {"NilNode",
       {Refusal, "`nil` (there is no boxed nil in the freestanding value model)"}},
      {"RationalNode",
       {Refusal, "a Rational literal"}},
      {"ImaginaryNode",
       {Refusal, "an imaginary literal"}},
      {"SplatNode",
       {Refusal, "a splat"}},
      {"MultiTargetNode",
       {Refusal, "a nested multiple-assignment target"}},
  };
  return t;
}

const std::map<std::string, std::string> &subsetRefusalCalls() {
  static const std::map<std::string, std::string> t = {
      {"**",
       "`**` is a power only on two Integers (decision 0042), exact at the declared width or a failure under the declared overflow policy. On any other operand it is a Float power, which needs libm's pow, or a method call on a heap object, and this one is not on two Integers."},
      {"[]",
       "`a[i]` indexes a heap object (Array / Hash / String), and there is no heap. The ONE exception is a parameter declared as a buffer -- `params: [[:u8_buf, :in], :len]` (E077) -- which is an address the CALLER owns and nothing allocates."},
      {"[]=",
       "`a[i] = v` writes into a heap object; see `[]`. A buffer declared `:out` or `:inout` is the exception."},
      {"to_s",
       "`to_s` builds a String, and a String is a heap object."},
      {"new",
       "`new` allocates."},
      {"each",
       "`each` without a literal block makes an Enumerator; with one it is a loop over a declared buffer (decision 0041)."},
      {"map",
       "`map` allocates the result Array."},
      {"times",
       "`times` without a literal block makes an Enumerator; with one it is a loop (decision 0041)."},
      {"push",
       "`push` grows an Array."},
      {"<<",
       "`<<` on an Array or String appends to a heap object. Only `<<` on a receiver typed Integer is a shift (decision 0042), and this receiver is not one."},
  };
  return t;
}

bool isHeapOperation(const std::string &kind) {
  auto row = subsetRefusalNodes().find(kind);
  return row != subsetRefusalNodes().end() &&
         row->second.core == CoreRule::HeapOperation;
}

} // namespace spinel_mlir::core
