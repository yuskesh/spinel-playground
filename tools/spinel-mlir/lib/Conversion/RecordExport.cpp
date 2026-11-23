#include "spinel/Conversion/RecordExport.h"

namespace spinel::consumer {
namespace {
void integerType(llvm::json::OStream &j, const record::FieldLayout &f) {
  j.object([&] {
    j.attribute("kind", "int");
    j.attribute("bits", f.bits);
    j.attribute("signed", f.isSigned);
    j.attribute("endianness", "little");
    j.attribute("alignment", f.bits / 8);
  });
}
} // namespace
ExportFields recordExport(std::shared_ptr<const record::Layout> layout,
                          size_t usedIndex, bool schema) {
  ExportFields out;
  if (schema) {
    out.emplace_back("symbol", layout->name);
    out.emplace_back("id", usedIndex);
  }
  out.emplace_back("size", layout->size);
  if (schema) {
    out.emplace_back("min_size", layout->size);
    out.emplace_back("alignment", layout->alignment);
    out.emplace_back("required_through", "");
    out.emplace_back("note", "Ruby Struct " + layout->name);
  }
  out.emplace_back(schema ? "fields" : "members", ExportValue::write(
      [layout = std::move(layout), schema](llvm::json::OStream &j) {
        j.array([&] {
          for (const auto &f : layout->fields) {
            if (f.padding) continue;
            j.object([&] {
              j.attribute("name", f.name);
              j.attribute("offset", f.offset);
              if (schema) {
                j.attribute("expose", "int");
                j.attribute("note", "");
                j.attributeBegin("type");
                if (f.count) {
                  j.object([&] {
                    j.attribute("kind", "array");
                    j.attribute("count", *f.count);
                    j.attributeBegin("element");
                    integerType(j, f);
                    j.attributeEnd();
                  });
                } else integerType(j, f);
                j.attributeEnd();
              } else {
                std::string type = f.type;
                if (f.count)
                  type = "[" + std::to_string(*f.count) + "]" + type;
                j.attribute("type", type);
              }
            });
          }
        });
      }));
  return out;
}
} // namespace spinel::consumer
