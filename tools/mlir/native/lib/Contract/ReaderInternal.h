// Internal, test-only face parsers. Individually parsed, unsealed typedump
// tables belong only to lib/Contract and unit tests, not install/include or
// consumers. Consumers receive only sealed ContractModule const accessors.
// Do not construct partial ContractModules from these types.
// Parser rules, fixed by ReaderTest: strict int64, with integer-overflow for
// out-of-range values. id/scope/slot/line/col/nparams cannot be negative. Only
// R-record -1 means no reference; -2 or less is negative-value. I values remain
// signed user integers. Decode producer ast_esc percent-hex escapes for
// SOURCE_FILE/FILE paths and S values only; preserve F spelling without double
// conversion. Missing two hex digits is malformed-escape. Diagnostics use
// <face>:<line>: <category>: <detail>, line 0 for face-wide omissions; categories
// must have ReaderTest/invalid.test coverage.
#ifndef SPINEL_MLIR_LIB_CONTRACT_READER_INTERNAL_H
#define SPINEL_MLIR_LIB_CONTRACT_READER_INTERNAL_H

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Contract/Reader.h"

#include "llvm/ADT/StringRef.h"

#include <vector>

namespace spinel_mlir::contract::internal {

// AST parse results retain input order; sealing canonicalizes them. *_line side tables supply
// actual AST record line numbers for cross-table diagnostics and are not in the public model.
struct ParsedAst {
  std::string sourceFile;
  std::vector<Source> files;
  int64_t root = -1;
  std::vector<Node> nodes;

  int64_t rootLine = 0;
  // (node id, field key) to record line, for R/A/I reference checks.
  struct FieldLine {
    int64_t node;
    std::string key;
    int64_t line;
  };
  std::vector<FieldLine> fieldLines;
};

// Individually parsed, unsealed tables for tests. Cross-face dangling references, missing scopes
// and parameter/slot matching belong to sealing.
struct ParsedContractTables {
  ParsedAst ast;
  std::vector<NodeType> nodeTypes;
  std::vector<Local> locals;
  std::vector<Method> methods;
};

// Face parsers return true on success; otherwise report the first diagnostic and false. out may be
// incomplete and must be discarded.
bool parseAstFace(llvm::StringRef text, ParsedAst &out,
                  ContractDiagnosticFn diag);
bool parseNodesFace(llvm::StringRef text, std::vector<NodeType> &out,
                    ContractDiagnosticFn diag);
bool parseLocalsFace(llvm::StringRef text, std::vector<Local> &out,
                     ContractDiagnosticFn diag);
bool parseMethodsFace(llvm::StringRef text, std::vector<Method> &out,
                      ContractDiagnosticFn diag);

} // namespace spinel_mlir::contract::internal

#endif // SPINEL_MLIR_LIB_CONTRACT_READER_INTERNAL_H
