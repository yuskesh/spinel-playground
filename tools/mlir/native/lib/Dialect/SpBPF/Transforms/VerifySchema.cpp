// Match map bindings to canonical schema. Initial maps [...] checks covered only
// structure/duplicates; this pass supplies existence/kind/key/value checks. Keep schema matching in
// the pass, not the dialect: the dialect owns eBPF vocabulary while callers choose a schema.
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h"

#include "spinel-mlir/Dialect/SpBPF/IR/SpBPFDialect.h"
#include "spinel-mlir/Target/SpBPF/Schema.h"

#include "llvm/Support/MemoryBuffer.h"

namespace mlir {
namespace spbpf {
#define GEN_PASS_DEF_SPBPFVERIFYSCHEMA
#include "spinel-mlir/Dialect/SpBPF/Transforms/Passes.h.inc"
} // namespace spbpf
} // namespace mlir

using namespace mlir;
using namespace mlir::spbpf;

namespace {

// Match schema and dialect types; initial slice is integer-only.
bool sameInt(const ::spbpf::Type &st, Type mt) {
  const auto *i = std::get_if<::spbpf::IntType>(&st.v);
  if (!i)
    return false;
  auto it = dyn_cast<IntegerType>(mt);
  return it && it.getWidth() == i->bits;
}

std::string describe(const ::spbpf::Type &st) {
  if (const auto *i = std::get_if<::spbpf::IntType>(&st.v))
    return (i->isSigned ? "i" : "u") + std::to_string(i->bits);
  if (std::holds_alternative<::spbpf::ArrayType>(st.v))
    return "an array";
  return "record " + std::get<::spbpf::RecordRefType>(st.v).symbol;
}

// Flatten integer record fields into (byte offset, bit width). Expand record_ref with accumulated
// offsets; arrays are raw payload, not integer stores, so do not expand them. A store_field into an
// array is refused as not naming an integer field.
void flattenIntFields(const ::spbpf::Schema &schema,
                      const ::spbpf::Record &rec, uint64_t base,
                      llvm::SmallVectorImpl<std::pair<uint64_t, unsigned>> &out) {
  for (const ::spbpf::Field &f : rec.fields) {
    if (const auto *i = std::get_if<::spbpf::IntType>(&f.type.v)) {
      out.push_back({base + f.offset, i->bits});
    } else if (const auto *r =
                   std::get_if<::spbpf::RecordRefType>(&f.type.v)) {
      for (const ::spbpf::Record &sub : schema.records())
        if (sub.symbol == r->symbol)
          flattenIntFields(schema, sub, base + f.offset, out);
    }
  }
}

const ::spbpf::Record *findRecord(const ::spbpf::Schema &schema,
                                  llvm::StringRef symbol) {
  for (const ::spbpf::Record &r : schema.records())
    if (r.symbol == symbol)
      return &r;
  return nullptr;
}

struct SpBPFVerifySchemaPass
    : public mlir::spbpf::impl::SpBPFVerifySchemaBase<SpBPFVerifySchemaPass> {
  using Base::Base;

  void runOnOperation() override {
    if (schemaPath.empty()) {
      getOperation().emitError()
          << "spbpf-verify-schema needs --schema=<path to the canonical schema>";
      return signalPassFailure();
    }
    auto buf = llvm::MemoryBuffer::getFile(schemaPath);
    if (!buf) {
      getOperation().emitError()
          << "cannot read schema " << schemaPath << ": "
          << buf.getError().message();
      return signalPassFailure();
    }
    auto schema = ::spbpf::Schema::parseJSON((*buf)->getBuffer());
    if (!schema) {
      getOperation().emitError()
          << "schema " << schemaPath << " is invalid: "
          << llvm::toString(schema.takeError());
      return signalPassFailure();
    }

    bool bad = false;
    getOperation().walk([&](ProgramOp prog) {
      // Check that the program itself is declared by schema; originally a different-name program
      // passed until loading failed. Explicit schema coverage controls matching. Never treat an
      // empty programs list as a bypass, since forgetting declarations would silently disable
      // checks.
      const bool checkPrograms =
          schema->coverage().programs == ::spbpf::Coverage::Complete;
      const ::spbpf::Program *pdecl = nullptr;
      for (const ::spbpf::Program &p : schema->programs())
        if (p.name == prog.getSymName())
          pdecl = &p;
      if (checkPrograms && !pdecl) {
        bad = true;
        prog.emitOpError() << "program @" << prog.getSymName()
                           << " is not declared in the schema "
                           << "(coverage.programs = complete)";
        return;
      }
      if (pdecl && pdecl->kind != prog.getKind()) {
        bad = true;
        prog.emitOpError() << "program @" << prog.getSymName()
                           << " is declared \"" << pdecl->kind
                           << "\" in the schema but written as \""
                           << prog.getKind() << "\"";
        return;
      }

      Block &entry = prog.getBody().front();
      ArrayAttr syms = prog.getMapSymbolsAttr();
      auto mapArgs = entry.getArguments().drop_front();
      for (auto [i, arg] : llvm::enumerate(mapArgs)) {
        auto flat = cast<FlatSymbolRefAttr>(syms[i]);
        StringRef sym = flat.getValue();

        const ::spbpf::Map *decl = nullptr;
        for (const ::spbpf::Map &m : schema->maps())
          if (m.symbol == sym)
            decl = &m;
        if (!decl) {
          bad = true;
          prog.emitOpError() << "map symbol @" << sym
                             << " is not declared in the schema";
          continue;
        }

        auto mt = cast<MapType>(arg.getType());
        const char *declKind = ::spbpf::mapKindName(decl->kind);
        if (mt.getKind() != declKind) {
          bad = true;
          prog.emitOpError() << "map @" << sym << " is declared \"" << declKind
                             << "\" in the schema but bound as \""
                             << mt.getKind() << "\"";
          continue;
        }
        if (!decl->key || !decl->value) {
          bad = true;
          prog.emitOpError() << "map @" << sym
                             << " has no key/value in the schema and cannot be "
                                "bound as a lookup map";
          continue;
        }
        if (!sameInt(*decl->key, mt.getKeyType())) {
          bad = true;
          prog.emitOpError() << "map @" << sym << " key type " << mt.getKeyType()
                             << " does not match the schema (" 
                             << describe(*decl->key) << ")";
        }
        if (!sameInt(*decl->value, mt.getValueType())) {
          bad = true;
          prog.emitOpError() << "map @" << sym << " value type "
                             << mt.getValueType()
                             << " does not match the schema ("
                             << describe(*decl->value) << ")";
        }
      }

      // Match ringbuf.reserve string names with schema ringbuf maps, turning string attributes into
      // schema-symbol references.
      prog.walk([&](RingbufReserveOp reserve) {
        StringRef name = reserve.getRingbuf();
        const ::spbpf::Map *decl = nullptr;
        for (const ::spbpf::Map &m : schema->maps())
          if (m.symbol == name)
            decl = &m;
        if (!decl) {
          bad = true;
          reserve.emitOpError() << "ring buffer \"" << name
                                << "\" is not declared in the schema";
          return;
        }
        if (decl->kind != ::spbpf::MapKind::RingBuf) {
          bad = true;
          reserve.emitOpError() << "\"" << name
                                << "\" is declared in the schema but is not a "
                                   "ringbuf map";
          return;
        }
        // Match reservation record type to schema record declaration. Do not silently permit scalar
        // IR reservation when schema declares a record, a mismatch unchecked in the earlier
        // implementation.
        auto resTy =
            cast<MaybeReservationType>(reserve.getResult().getType());
        if (auto rt = dyn_cast<RecordType>(resTy.getRecordType())) {
          if (decl->record.empty()) {
            bad = true;
            reserve.emitOpError()
                << "reserves record \"" << rt.getSymbol() << "\" but the "
                << "schema ringbuf \"" << name << "\" declares no record";
            return;
          }
          if (decl->record != rt.getSymbol()) {
            bad = true;
            reserve.emitOpError()
                << "reserves record \"" << rt.getSymbol()
                << "\" but the schema ringbuf \"" << name
                << "\" carries record \"" << decl->record << "\"";
            return;
          }
          const ::spbpf::Record *rec = findRecord(*schema, rt.getSymbol());
          if (!rec) {
            bad = true;
            reserve.emitOpError() << "record \"" << rt.getSymbol()
                                  << "\" is not declared in the schema";
            return;
          }
          if (rec->size != (uint64_t)rt.getSize()) {
            bad = true;
            reserve.emitOpError()
                << "record \"" << rt.getSymbol() << "\" is " << rec->size
                << " bytes in the schema but the reservation type says "
                << rt.getSize();
          }
        } else if (!decl->record.empty()) {
          bad = true;
          reserve.emitOpError()
              << "the schema ringbuf \"" << name << "\" carries record \""
              << decl->record << "\" but the reservation type is "
              << resTy.getRecordType()
              << " — reserve it as !spbpf.record<...> so the layout is checked";
        }
      });

      // store_field offset/width must name an integer field in schema.
      prog.walk([&](RingbufStoreFieldOp sf) {
        auto res = cast<ReservationType>(sf.getReservation().getType());
        auto rt = dyn_cast<RecordType>(res.getRecordType());
        if (!rt)
          return; // Already refused by dialect verification.
        const ::spbpf::Record *rec = findRecord(*schema, rt.getSymbol());
        if (!rec) {
          bad = true;
          sf.emitOpError() << "record \"" << rt.getSymbol()
                           << "\" is not declared in the schema";
          return;
        }
        unsigned bits = cast<IntegerType>(sf.getValue().getType()).getWidth();
        llvm::SmallVector<std::pair<uint64_t, unsigned>, 16> fields;
        flattenIntFields(*schema, *rec, 0, fields);
        for (auto [off, w] : fields)
          if (off == (uint64_t)sf.getOffset() && w == bits)
            return;
        bad = true;
        auto d = sf.emitOpError()
                 << "no integer field of record \"" << rt.getSymbol()
                 << "\" sits at offset " << sf.getOffset() << " with width "
                 << bits << " bits";
        std::string have;
        for (auto [off, w] : fields) {
          if (!have.empty())
            have += ", ";
          have += "i" + std::to_string(w) + "@" + std::to_string(off);
        }
        d.attachNote() << "schema fields (after expanding record_ref): " << have;
      });
    });

    // coverage.programs=complete also requires every schema program in IR; check both directions.
    if (schema->coverage().programs == ::spbpf::Coverage::Complete) {
      for (const ::spbpf::Program &decl : schema->programs()) {
        bool found = false;
        getOperation().walk([&](ProgramOp p) {
          if (p.getSymName() == decl.name)
            found = true;
        });
        if (!found) {
          bad = true;
          getOperation().emitError()
              << "the schema declares program @" << decl.name
              << " (coverage.programs = complete) but this module does not "
                 "define it";
        }
      }
    }

    if (bad)
      signalPassFailure();
  }
};

} // namespace
