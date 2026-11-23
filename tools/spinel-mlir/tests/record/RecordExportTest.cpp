#include "spinel/Conversion/RecordExport.h"
#include "llvm/Support/raw_ostream.h"
#include <cstdio>
using namespace spinel::consumer;
static std::string render(const ExportFields &fields) {
  std::string text;
  llvm::raw_string_ostream stream(text);
  llvm::json::OStream j(stream);
  j.object([&] {
    for (const auto &field : fields) {
      j.attributeBegin(field.first);
      if (field.second.writer) field.second.writer(j);
      else j.value(*field.second.primitive);
      j.attributeEnd();
    }
  });
  return text;
}
int main() {
  auto outcome = spinel::record::layout("P", {"a", "_pad0", "b"},
      {{"a", "u8", {}}, {"_pad0", "u8", {}}, {"b", "i16", {}}});
  auto layout = std::make_shared<const spinel::record::Layout>(outcome.layout);
  auto schema = recordExport(layout, 2, true);
  auto maps = recordExport(layout, 2, false);
  layout.reset(); // Writers must own all values after the caller releases them.
  const std::string expectedSchema =
    R"({"symbol":"P","id":2,"size":4,"min_size":4,"alignment":2,"required_through":"","note":"Ruby Struct P","fields":[{"name":"a","offset":0,"expose":"int","note":"","type":{"kind":"int","bits":8,"signed":false,"endianness":"little","alignment":1}},{"name":"b","offset":2,"expose":"int","note":"","type":{"kind":"int","bits":16,"signed":true,"endianness":"little","alignment":2}}]})";
  const std::string expectedMaps =
    R"({"size":4,"members":[{"name":"a","offset":0,"type":"u8"},{"name":"b","offset":2,"type":"i16"}]})";
  if (render(schema) != expectedSchema || render(maps) != expectedMaps) {
    std::fprintf(stderr, "FAIL record scalar order/padding/owned writer\n");
    return 1;
  }
  auto hist = spinel::record::layout("Hist", {"hist", "n"},
      {{"hist", "u32", 8}, {"n", "u64", {}}});
  auto arrayLayout = std::make_shared<const spinel::record::Layout>(hist.layout);
  auto arraySchema = render(recordExport(arrayLayout, 0, true));
  auto arrayMaps = render(recordExport(arrayLayout, 0, false));
  if (arraySchema.find(R"("type":{"kind":"array","count":8,"element":{"kind":"int","bits":32,"signed":false,"endianness":"little","alignment":4}})") == std::string::npos ||
      arrayMaps != R"({"size":40,"members":[{"name":"hist","offset":0,"type":"[8]u32"},{"name":"n","offset":32,"type":"u64"}]})") {
    std::fprintf(stderr, "FAIL record array type order/offset/spelling\n");
    return 1;
  }
  return 0;
}
