// Schema C ABI implementation; ownership is defined in spinel-mlir-c/SpBPF.h comments and followed
// here.
#include "spinel-mlir-c/SpBPF.h"

#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

namespace {

// Strings crossing into C are malloc-allocated and freed through sp_bpf_string_destroy.
char *dupToC(const std::string &s) {
  char *out = static_cast<char *>(std::malloc(s.size() + 1));
  if (!out)
    return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

} // namespace

struct SpBpfSchema {
  spbpf::Schema schema;
};

extern "C" {

SpBpfSchema *sp_bpf_schema_parse_json(const char *json, size_t len,
                                      char **error_out) {
  if (!json) {
    if (error_out)
      *error_out = dupToC("sp_bpf_schema_parse_json: json is NULL");
    return nullptr;
  }
  auto parsed = spbpf::Schema::parseJSON(llvm::StringRef(json, len));
  if (!parsed) {
    std::string msg = llvm::toString(parsed.takeError());
    if (error_out)
      *error_out = dupToC(msg);
    return nullptr;
  }
  auto *handle = new (std::nothrow) SpBpfSchema{std::move(*parsed)};
  if (!handle && error_out)
    *error_out = dupToC("sp_bpf_schema_parse_json: out of memory");
  return handle;
}

char *sp_bpf_schema_serialize_json(const SpBpfSchema *schema) {
  if (!schema)
    return nullptr;
  return dupToC(schema->schema.serializeJSON());
}

void sp_bpf_schema_destroy(SpBpfSchema *schema) { delete schema; }

void sp_bpf_string_destroy(char *s) { std::free(s); }

} // extern "C"
