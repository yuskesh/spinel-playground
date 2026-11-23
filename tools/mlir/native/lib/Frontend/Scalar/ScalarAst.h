//===- ScalarAst.h - field access on a sealed ContractModule's ast face ---===//
//
// E160.  The four accessors both halves of the scalar front end (the selector
// in Importer.cpp and the MLIR builder in MlirGen.cpp) need to read a Node's
// named fields.  They live here rather than being written twice because the
// two halves have to agree on what "this field is absent" means: a Reference
// of -1 is prism's "no child", and a field of the wrong record tag is an input
// that is not spinel-typedump output at all.  Two copies of that rule would be
// two places for it to drift.
//
// Internal to lib/Frontend/Scalar — not a public header.
//===----------------------------------------------------------------------===//
#ifndef SPINEL_MLIR_LIB_FRONTEND_SCALAR_SCALARAST_H
#define SPINEL_MLIR_LIB_FRONTEND_SCALAR_SCALARAST_H

#include "spinel-mlir/Contract/Model.h"

#include "llvm/ADT/StringRef.h"
#include "llvm/ADT/Twine.h"

#include <cstdint>
#include <string>
#include <variant>
#include <vector>

namespace spinel_mlir::scalar::ast {

inline const contract::AstField *findField(const contract::Node &node,
                                           llvm::StringRef key) {
  for (const contract::AstField &field : node.fields)
    if (field.key == key)
      return &field;
  return nullptr;
}

inline bool getReference(const contract::Node &node, llvm::StringRef key,
                         int64_t &out) {
  const contract::AstField *field = findField(node, key);
  if (!field || field->kind != contract::AstField::Kind::Reference ||
      !std::holds_alternative<int64_t>(field->value))
    return false;
  out = std::get<int64_t>(field->value);
  return true;
}

inline bool getString(const contract::Node &node, llvm::StringRef key,
                      std::string &out) {
  const contract::AstField *field = findField(node, key);
  if (!field || field->kind != contract::AstField::Kind::String ||
      !std::holds_alternative<std::string>(field->value))
    return false;
  out = std::get<std::string>(field->value);
  return true;
}

inline bool getInteger(const contract::Node &node, llvm::StringRef key,
                       int64_t &out) {
  const contract::AstField *field = findField(node, key);
  if (!field || field->kind != contract::AstField::Kind::Integer ||
      !std::holds_alternative<int64_t>(field->value))
    return false;
  out = std::get<int64_t>(field->value);
  return true;
}

// Float literal spelling. Contract keeps AstField::Kind::FloatSpelling without rounding to double;
// consumers receive the spelling and parse it themselves.
inline bool getFloatSpelling(const contract::Node &node, llvm::StringRef key,
                             std::string &out) {
  for (const contract::AstField &field : node.fields) {
    if (field.key != key ||
        field.kind != contract::AstField::Kind::FloatSpelling)
      continue;
    out = std::get<std::string>(field.value);
    return true;
  }
  return false;
}

inline bool getArray(const contract::Node &node, llvm::StringRef key,
                     std::vector<int64_t> &out) {
  const contract::AstField *field = findField(node, key);
  if (!field || field->kind != contract::AstField::Kind::Array ||
      !std::holds_alternative<std::vector<int64_t>>(field->value))
    return false;
  out = std::get<std::vector<int64_t>>(field->value);
  return true;
}

inline std::string quote(llvm::StringRef text) {
  return (llvm::Twine("'") + text + "'").str();
}

} // namespace spinel_mlir::scalar::ast

#endif // SPINEL_MLIR_LIB_FRONTEND_SCALAR_SCALARAST_H
