// Immutable, MLIR-independent model of the Spinel frontend contract.
// Preserves all four typedump faces: ast, nodes, locals and methods.
// Depends on LLVM ADTs, not MLIR or spbpf::Schema. Only ContractBuilder in
// lib/Contract constructs it; consumers receive const accessors, not mutable
// containers. Float source spelling stays a string, avoiding double rounding.
// The reader returns a module only after parsing all faces and checking every
// cross-table reference; no partial model is exposed.
#ifndef SPINEL_MLIR_CONTRACT_MODEL_H
#define SPINEL_MLIR_CONTRACT_MODEL_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

namespace spinel_mlir::contract {

// One FILE-table row; AST node_file fields refer to its id.
struct Source {
  int64_t id;
  std::string path;
};

// One named AST field, corresponding to producer record tags S/I/F/R/A.
struct AstField {
  enum class Kind { String, Integer, FloatSpelling, Reference, Array };
  Kind kind;
  std::string key;
  // Zero-based producer order, excluded from canonicalization. Model fields are
  // sorted by key, which differs from producer order. The frozen Python
  // Ast.subtree walks last-in-first-out and pushes children in producer order.
  // Changing that order changes the first user-visible refusal: CallNode emits
  // receiver, arguments, block, so arguments pop before receiver; lexical order
  // reverses that. For s = "n=" + n.to_s, the Python first cause was to_s, while
  // native reported StringNode. Only stage 1 traversal reads this index; exclude
  // it from sealing and dumping so canonical bytes remain unchanged.
  unsigned producerOrder = 0;
  // String / FloatSpelling -> std::string, preserving source spelling.
  // Integer / Reference -> int64_t; reference -1 means absent.
  // Array -> std::vector<int64_t> of node ids; empty is valid.
  std::variant<std::string, int64_t, std::vector<int64_t>> value;
};

// One ast-face node; ids are unique within the face (duplicates are refused).
struct Node {
  int64_t id;
  std::string kind;
  std::vector<AstField> fields;
};

// One nodes-face row: inferred type and position for a node id.
struct NodeType {
  int64_t id, scope, line, column;
  std::string kind, type, scopeName, detail;
};

/// A node the analysis REWROTE IN PLACE, so the nodes face gives it another
/// kind than the parse. Two rewrites are recognised, each by its exact shape
/// (the reader refuses any other mismatch):
///
///   * `AnonymousModule`: upstream's desugar of `Module.new { ... }` turns the
///     CallNode into a ConstantReadNode naming the anonymous module it made
///     (`SpinelAnon...`). `synthesized` lists the nodes the same desugar ADDED
///     (that module's ModuleNode and constant, at the call's position); the ast
///     has no such ids, so their rows are not carried in nodeTypes().
///   * `DeadBranch`: upstream removes a definition written in a branch that
///     cannot run, replacing every node of that branch with a NilNode. `id` is
///     the IfNode or UnlessNode; `replaced` lists the branch's nodes.
///   * `DynamicSend`: upstream lowers `send(name, ...)` whose name is not a
///     literal into a dispatch over the program's symbol literals, adding one
///     candidate CallNode per name (with an ArgumentsNode when arguments
///     remain) and, for a receiverless send, a SelfNode receiver. `id` is the
///     send; `synthesized` lists the added nodes, whose rows are not carried.
///   * `PrunedMethod`: upstream leaves out of the analysis a method whose name
///     no other node of the program holds, replacing every node of its
///     definition with a NilNode. `id` is the DefNode, `detail` its name;
///     `replaced` lists the definition's nodes. Nothing can call it by name,
///     so it is outside every call closure.
///   * `ParenPeel`: a desugar puts the one expression a pair of parentheses
///     wraps in the parentheses' place and turns the ParenthesesNode and its
///     StatementsNode into NilNodes. The expression keeps its kind. `id` is
///     the ParenthesesNode; `replaced` lists it and its StatementsNode.
///
/// Carried so a checker can refuse the program at that node and say why,
/// rather than read a contract whose two faces disagree.
struct AnalysisRewrite {
  enum class Kind { AnonymousModule, DeadBranch, DynamicSend, PrunedMethod, ParenPeel };
  Kind rewrite;
  int64_t id;
  std::string astKind, nodesKind, detail;
  std::vector<int64_t> synthesized;
  std::vector<int64_t> replaced;
};

// One locals-face row; (scope, slot) is unique within the face.
struct Local {
  int64_t scope, slot;
  std::string scopeName, name, type;
  bool isParam, isCell, nullableInt;
};

struct Parameter {
  std::string name, type;
};

// One methods-face row. scalarAbi preserves the producer's abi_scalar verdict:
// canonical scalar ABI means every parameter and the result are integers.
struct Method {
  int64_t scope;
  std::string name, className, returnType;
  std::vector<Parameter> parameters;
  bool scalarAbi;
};

/// Decision 0045: a buffer call the CORE reader found in the source text
/// (Core/BufferSpelling.h). `line` is the source's line and `column` the
/// call's first byte on it, as the AST face counts them. For a rewritten
/// `Core::Buffer` or `Core::Table` the analysis saw `Array.new` at that
/// place; an `ArrayNew` row is a spelling of the source's own. A `Reserved`
/// row is a definition of `Core::Buffer` or `Core::Table` (its `element`)
/// that the source makes, `arguments` saying what it defines ("a module").
struct BufferSpelling {
  enum class Kind { Buffer, Table, ArrayNew, Reserved };
  Kind kind;
  int64_t line, column;
  std::string element;   ///< the name after the class (`i32`); empty for ArrayNew
  std::string arguments; ///< the text between the parentheses, as written
};

/// Decision 0045: text the CORE reader inserted into its copy of the source
/// (Core/BufferSpelling.h): `length` bytes at the source's `line` and
/// `column`. The contract reader moves every node after it on that line
/// back by `length` (ContractInputs::columnInserts), so the module, and
/// every column a refusal prints, is the source's.
struct ColumnInsert {
  int64_t line, column, length;
};

/// The source column of `col`, a column of the reader's copy on the
/// source's `line`: back by the inserted lengths before it on that line; a
/// column inside inserted text is the insertion's own. `inserts` are in
/// order.
inline int64_t sourceColumn(llvm::ArrayRef<ColumnInsert> inserts, int64_t line, int64_t col) {
  int64_t shift = 0;
  for (const ColumnInsert &in : inserts) {
    if (in.line != line) continue;
    const int64_t at = in.column + shift;  // the insertion's column in the copy
    if (col >= at + in.length) shift += in.length;
    else if (col >= at) return in.column;
    else break;
  }
  return col - shift;
}

// Immutable model available only after all four faces and references validate.
// Canonical order: files/nodes/types by id, locals by (scope, slot), methods by
// scope, independent of input order or consumer preferences.
class ContractModule {
public:
  llvm::StringRef sourceFile() const { return sourceFile_; }

  // Normalize when the file read and its intended identity differ. Two-stage
  // type inference runs typedump on synthetic source; otherwise temporary paths
  // leak into FileLineColLoc and diagnostics, pointing to files already removed.
  // The caller is responsible for restoring the original source identity here.
  void setSourceFile(llvm::StringRef path) { sourceFile_ = path.str(); }
  /// The same for each row of the file table: a caller that analysed copies
  /// (the freestanding emitter's second stage) maps each copy's path back
  /// to the file it copied, so a required file's nodes are located there.
  /// `rename` returns the path to keep.
  void renameSources(llvm::function_ref<std::string(llvm::StringRef)> rename) {
    for (Source &s : sources_) s.path = rename(s.path);
  }
  int64_t root() const { return root_; }
  llvm::ArrayRef<Source> sources() const { return sources_; }
  llvm::ArrayRef<Node> nodes() const { return nodes_; }
  llvm::ArrayRef<NodeType> nodeTypes() const { return nodeTypes_; }
  llvm::ArrayRef<Local> locals() const { return locals_; }
  llvm::ArrayRef<Method> methods() const { return methods_; }
  llvm::ArrayRef<AnalysisRewrite> analysisRewrites() const { return rewrites_; }
  /// Decision 0045: set by the CORE reader (core::loadContract) for the
  /// source file; empty when the source spells no buffer call.
  llvm::ArrayRef<BufferSpelling> bufferSpellings() const { return spellings_; }
  void setBufferSpellings(std::vector<BufferSpelling> s) { spellings_ = std::move(s); }

private:
  friend class ContractBuilder; // Only the lib/Contract builder constructs this.
  ContractModule() = default;

  std::string sourceFile_;
  int64_t root_ = -1;
  std::vector<Source> sources_;
  std::vector<Node> nodes_;
  std::vector<NodeType> nodeTypes_;
  std::vector<Local> locals_;
  std::vector<Method> methods_;
  std::vector<AnalysisRewrite> rewrites_;
  std::vector<BufferSpelling> spellings_;
};

} // namespace spinel_mlir::contract

#endif // SPINEL_MLIR_CONTRACT_MODEL_H
