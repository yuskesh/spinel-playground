//===- BufferSpelling.h - Core::Buffer and Core::Table (decision 0045) -*- C++ -*-===//
//
// A CORE kernel spells a buffer it makes as `Core::Buffer.i32(n, 2)` (or
// `::Core::Buffer...`), and a read-only table as `Core::Table.f64(n) { }`.
// The pinned analysis knows neither class, and the vendor is read-only, so
// the CORE reader hands the analysis a copy in which each such call is the
// `Array.new(n, v)` the routes already read, and keeps a record of what was
// written there.
//
// The copy keeps every line and the call's starting column. `Array.new(` is
// padded with spaces to the width of the head it replaces, so each argument
// keeps its column too (the analysis gives a node only its start). An omitted
// fill is appended as `, 0` (`, 0.0` for f32 and f64), and a Float buffer's
// Integer literal fill gets `.0`. Those insertions move what follows them on
// their line, so they are recorded, and the contract reader moves each node
// after one back to the source's column.
//
// A source with a syntax error is not rewritten at all, so the reader's own
// diagnostics stand. The calls are found by parsing the source with the vendored Prism
// (vendor/spinel/build/libprism.a, as the contract reader links it), so
// strings, heredocs, comments and `=begin` are Prism's to read. A call is
// recognised only with its parenthesis straight after the element name; any
// other `Core::Buffer` spelling is left as it is, for the checker to refuse.
// `Doom::Core::Buffer` (a constant inside another module) is not matched.
// Every `Array.new` the source spells is recorded too, with its argument
// text, so the refusal of that spelling can suggest the rewrite. So is every
// definition of `Core::Buffer` or `Core::Table` (a module, class, constant
// or method), which the checker refuses in a source it rewrote.
//
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_CORE_BUFFERSPELLING_H
#define SPINEL_MLIR_CORE_BUFFERSPELLING_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/StringRef.h"

#include <string>
#include <vector>

namespace spinel_mlir::core {

struct BufferRewrite {
  std::string text;  ///< the copy, or the source unchanged
  bool changed = false;
  std::vector<contract::BufferSpelling> spelled;
  /// The text inserted (a default fill, a Float fill's `.0`), in the
  /// source's lines and columns and in order (ContractInputs::columnInserts).
  std::vector<contract::ColumnInsert> inserts;
};

/// The copy of `source` and its record (see above).
BufferRewrite rewriteBufferSpellings(llvm::StringRef source);

/// Text a reader printed about the copy at `copyPath`, its lines already the
/// source's (Core/Prelude.h, sourceLines), with each `copyPath:LINE:COL` on a
/// line the rewrite inserted text into moved back to the source's column,
/// as the contract reader moves the nodes (the review).
std::string sourceColumns(llvm::StringRef text, llvm::StringRef copyPath,
                          llvm::ArrayRef<contract::ColumnInsert> inserts);

/// Whether `name` is one of the boundary's element names
/// (i8 i16 i32 i64 u8 u16 u32 f32 f64).
bool isBufferElement(llvm::StringRef name);

} // namespace spinel_mlir::core

#endif // SPINEL_MLIR_CORE_BUFFERSPELLING_H
