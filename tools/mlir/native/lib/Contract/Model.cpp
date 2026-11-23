// Test-only canonical dump, not a new frontend protocol. minimal.canonical and
// canonical.test define the format. Preserve sealed order: files/nodes/types
// by id, fields by key, locals by (scope, slot), methods by scope. Re-escape
// decoded paths and S values with producer escapes (%/newline/CR/tab/space/NUL
// to %XX), preserving line/space-based parsing. Keep float spelling unchanged.
// Nodes-face scope_name/detail/type names are already unescaped TSV cells
// without tabs/newlines. Detail is last, so spaces remain unambiguous.
#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Contract/Reader.h"

#include "llvm/Support/raw_ostream.h"

namespace spinel_mlir::contract {

namespace {

void escaped(llvm::raw_ostream &os, llvm::StringRef s) {
  static const char hex[] = "0123456789ABCDEF";
  for (unsigned char c : s) {
    if (c == '%' || c == '\n' || c == '\r' || c == '\t' || c == ' ' || c == 0)
      os << '%' << hex[c >> 4] << hex[c & 15];
    else
      os << static_cast<char>(c);
  }
}

} // namespace

void printCanonical(const ContractModule &m, llvm::raw_ostream &os) {
  os << "source ";
  escaped(os, m.sourceFile());
  os << "\n";
  for (const Source &s : m.sources()) {
    os << "file " << s.id << " ";
    escaped(os, s.path);
    os << "\n";
  }
  os << "root " << m.root() << "\n";
  for (const Node &n : m.nodes()) {
    os << "node " << n.id << " " << n.kind << "\n";
    for (const AstField &f : n.fields) {
      os << "  field " << f.key << " ";
      switch (f.kind) {
      case AstField::Kind::String:
        os << "string ";
        escaped(os, std::get<std::string>(f.value));
        break;
      case AstField::Kind::Integer:
        os << "integer " << std::get<int64_t>(f.value);
        break;
      case AstField::Kind::FloatSpelling:
        os << "float " << std::get<std::string>(f.value);
        break;
      case AstField::Kind::Reference:
        os << "ref " << std::get<int64_t>(f.value);
        break;
      case AstField::Kind::Array: {
        os << "array [";
        const auto &ids = std::get<std::vector<int64_t>>(f.value);
        for (size_t i = 0; i < ids.size(); ++i)
          os << (i ? "," : "") << ids[i];
        os << "]";
        break;
      }
      }
      os << "\n";
    }
  }
  for (const NodeType &t : m.nodeTypes())
    os << "type " << t.id << " kind=" << t.kind << " type=" << t.type
       << " scope=" << t.scope << " scope_name=" << t.scopeName
       << " line=" << t.line << " col=" << t.column << " detail=" << t.detail
       << "\n";
  for (const Local &l : m.locals())
    os << "local scope=" << l.scope << " slot=" << l.slot
       << " scope_name=" << l.scopeName << " name=" << l.name
       << " type=" << l.type << " param=" << (l.isParam ? 1 : 0)
       << " cell=" << (l.isCell ? 1 : 0)
       << " nullable_int=" << (l.nullableInt ? 1 : 0) << "\n";
  for (const Method &me : m.methods()) {
    os << "method scope=" << me.scope << " name=" << me.name
       << " class=" << me.className << " return=" << me.returnType
       << " abi_scalar=" << (me.scalarAbi ? "yes" : "no") << "\n";
    for (size_t i = 0; i < me.parameters.size(); ++i)
      os << "  param " << i << " " << me.parameters[i].name << " "
         << me.parameters[i].type << "\n";
  }
}

} // namespace spinel_mlir::contract
