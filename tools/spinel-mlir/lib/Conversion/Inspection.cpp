#include "spinel/Conversion/Inspection.h"
#include <utility>

namespace spinel::inspection {
std::string quote(const std::string &value) {
  static const char digits[] = "0123456789abcdef";
  std::string out = "\"";
  for (size_t i = 0; i < value.size();) {
    auto c = static_cast<unsigned char>(value[i]);
    if (c < 0x80) {
      ++i;
      switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20 || c == '<' || c == '>' || c == '&') {
          out += "\\u00";
          out += digits[c >> 4];
          out += digits[c & 15];
        } else out += static_cast<char>(c);
      }
      continue;
    }
    // Go's utf8.DecodeRuneInString consumes one byte on an invalid sequence.
    unsigned length = c >= 0xc2 && c <= 0xdf ? 2 :
                      c >= 0xe0 && c <= 0xef ? 3 :
                      c >= 0xf0 && c <= 0xf4 ? 4 : 0;
    bool valid = length && i + length <= value.size();
    for (unsigned j = 1; valid && j < length; ++j) {
      auto next = static_cast<unsigned char>(value[i+j]);
      valid = next >= 0x80 && next <= 0xbf;
      if (j == 1)
        valid = valid && !(c == 0xe0 && next < 0xa0) &&
                !(c == 0xed && next > 0x9f) &&
                !(c == 0xf0 && next < 0x90) &&
                !(c == 0xf4 && next > 0x8f);
    }
    if (!valid) { out += "\xef\xbf\xbd"; ++i; continue; }
    if (length == 3 && c == 0xe2 &&
        static_cast<unsigned char>(value[i+1]) == 0x80 &&
        (static_cast<unsigned char>(value[i+2]) == 0xa8 ||
         static_cast<unsigned char>(value[i+2]) == 0xa9))
      out += static_cast<unsigned char>(value[i+2]) == 0xa8 ? "\\u2028" : "\\u2029";
    else out.append(value, i, length);
    i += length;
  }
  return out + '"';
}
namespace {
using Fields = std::vector<std::pair<std::string, std::string>>;
std::string pad(unsigned n) { return std::string(n, ' '); }
std::string object(const Fields &fields, unsigned indent) {
  if (fields.empty()) return "{}";
  std::string out = "{\n";
  for (size_t i = 0; i < fields.size(); ++i) {
    out += pad(indent+2) + quote(fields[i].first) + ": " + fields[i].second;
    out += i + 1 == fields.size() ? "\n" : ",\n";
  }
  return out + pad(indent) + '}';
}
std::string array(const std::vector<std::string> &values, unsigned indent) {
  if (values.empty()) return "[]";
  std::string out = "[\n";
  for (size_t i = 0; i < values.size(); ++i) {
    out += pad(indent+2) + values[i];
    out += i + 1 == values.size() ? "\n" : ",\n";
  }
  return out + pad(indent) + ']';
}
std::string strings(const std::vector<std::string> &values, unsigned indent) {
  std::vector<std::string> result;
  for (const auto &value : values) result.push_back(quote(value));
  return array(result, indent);
}
std::string position(const Position &p, unsigned indent) {
  return object({{"file",quote(p.file)}, {"line",std::to_string(p.line)},
                 {"col",std::to_string(p.col)}},indent);
}
} // namespace
std::string writeDomain(const Domain &d) {
  std::vector<std::string> roots, functions, edges, diagnostics;
  for (const auto &r : d.roots)
    roots.push_back(object({{"name",quote(r.name)}, {"kind",quote(r.kind)},
                            {"decl",position(r.decl,6)},
                            {"def",position(r.def,6)}},4));
  for (const auto &f : d.functions)
    functions.push_back(object({{"name",quote(f.name)},
                                {"membership",strings(f.membership,6)}},4));
  for (const auto &e : d.edges)
    edges.push_back(object({{"from",quote(e.from)}, {"to",quote(e.to)},
                            {"pos",position(e.pos,6)},
                            {"dispatch",quote(e.dispatch)}},4));
  for (const auto &diag : d.diagnostics) {
    Fields fields = {{"verdict",quote(diag.verdict)}, {"code",quote(diag.code)},
                     {"name",quote(diag.name)}, {"pos",position(diag.pos,6)}};
    if (!diag.path.empty()) fields.emplace_back("path",strings(diag.path,6));
    fields.emplace_back("message",quote(diag.message));
    diagnostics.push_back(object(fields,4));
  }
  return object({{"source",quote(d.source)}, {"roots",array(roots,2)},
                 {"functions",array(functions,2)}, {"edges",array(edges,2)},
                 {"diagnostics",array(diagnostics,2)}},0) + '\n';
}
} // namespace spinel::inspection
