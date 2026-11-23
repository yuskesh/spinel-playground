//===- BlockLoops.h - literal blocks on iterator calls --------*- C++ -*-===//
//
// Decision 0041, stage 1: `n.times { |i| ... }`, `a.upto(b) { ... }`,
// `a.downto(b) { ... }`, and `buf.each { |x| ... }` and
// `buf.each_with_index { |x, i| ... }` on a declared buffer are loops whose
// body is the block. The block is a compile-time entity: it is inlined where
// it is written, and no Proc exists.
//
// This header is the one owner of which calls are such loops. The importer,
// the freestanding subset walk, the CORE checker, the loop bounds and the
// lowering all ask it, so none of them can admit a shape another refuses.
//
// It depends on the contract model only, not on MLIR.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_BLOCKLOOPS_H
#define SPINEL_MLIR_CORE_BLOCKLOOPS_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/STLFunctionalExtras.h"
#include "llvm/ADT/StringRef.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace spinel_mlir::core {

using BlockLoopLookup =
    llvm::function_ref<const contract::Node *(int64_t)>;

struct BlockLoop {
  enum class Kind { Times, Upto, Downto, Each, EachWithIndex };
  Kind kind;
  int64_t call = -1;
  int64_t receiver = -1;
  /// The one argument of `upto` and `downto`; -1 otherwise.
  int64_t limit = -1;
  int64_t block = -1;
  /// The block's StatementsNode, or -1 for an empty block.
  int64_t body = -1;
  /// The block's parameters in order, at most what the call yields.
  std::vector<std::string> params;
  /// Their RequiredParameterNodes, in the same order.
  std::vector<int64_t> paramNodes;
  /// The block's own locals that are not parameters. Ruby makes them afresh
  /// on every call of the block, so each iteration starts without them.
  std::vector<std::string> locals;
  /// The nodes the loop accounts for by position: the BlockNode and its
  /// parameter nodes, and the call's ArgumentsNode. They are not
  /// expressions, and a walker that meets them as such must skip them.
  std::vector<int64_t> structural;
};

/// The Ruby name of a loop kind.
llvm::StringRef blockLoopName(BlockLoop::Kind kind);

/// How many values the call yields to its block: 2 for `each_with_index`,
/// 1 for the others.
unsigned blockLoopYields(BlockLoop::Kind kind);

/// What `call` is, as far as literal blocks go.
struct BlockLoopShape {
  /// Set when the call is an admitted loop.
  std::optional<BlockLoop> loop;
  /// Set when the call has a block (or a block argument) and is not an
  /// admitted loop: why, in a sentence that names the construct.
  std::optional<std::string> refusal;
};

/// Classify a CallNode. A call with no block and no block argument gives
/// neither field. Whether an `each` receiver is a declared buffer is the
/// caller's question, since only the caller knows its buffers.
BlockLoopShape classifyBlockLoop(const contract::Node &call,
                                 BlockLoopLookup lookup);

/// A block parameter that shadows a local of an enclosing scope. Ruby gives
/// the parameter a variable of its own, and the analysis gives a method's
/// locals one slot per name, so the two would share one; the subset refuses
/// it instead.
struct ShadowedParameter {
  int64_t node = -1;
  std::string name;
};

/// The first name of an admitted loop's block under `def` (a parameter, or a
/// local of the block's own) that an enclosing scope also owns: a method
/// parameter, or a local of the method or of an enclosing block, wherever in
/// the method it is written. `node` is the parameter, or the BlockNode for a
/// local.
std::optional<ShadowedParameter> findShadowedParameter(const contract::Node &def,
                                                       BlockLoopLookup lookup);

/// The analysis's slot for the name `written` that `loop`'s block declares (a
/// parameter, or a local of its own). Spinel may give such a name a slot of
/// its own under another name (`written__b...`); the AST keeps the written
/// name, and the nodes face names the slot on the node that declares it: the
/// parameter's RequiredParameterNode, or the block's first
/// LocalVariableWriteNode of the local. The slot is read there rather than
/// spelled here, since the spelling is Spinel's and has changed (the pin's
/// `written__bp<block>`, upstream's per-method tag since 2026-11). Answers
/// that slot when it starts with `written__b` and `hasSlot` knows it, and
/// `written` otherwise.
std::string blockSlotName(llvm::StringRef written, const BlockLoop &loop,
                          BlockLoopLookup lookup,
                          llvm::function_ref<std::string(int64_t)> analysedName,
                          llvm::function_ref<bool(llvm::StringRef)> hasSlot);

/// Every admitted loop under `def`, outermost first, in source order.
std::vector<BlockLoop> blockLoopsUnder(const contract::Node &def,
                                       BlockLoopLookup lookup);

} // namespace spinel_mlir::core
#endif
