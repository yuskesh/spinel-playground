#pragma once
#include "mlir/IR/Builders.h"
#include "spinel/Analysis/GroupARange.h"
#include "spinel/Analysis/RecordLayout.h"
#include "llvm/Support/JSON.h"
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <vector>
namespace spinel::consumer {
class Consumer;
struct ScalarExpr;
using Expr = std::shared_ptr<ScalarExpr>;
struct Payload;
struct ProgramDecl {
  std::string name;
  std::vector<size_t> maps;
  std::string kind = "xdp", attachTarget;
  mlir::Type contextType;
  mlir::Operation *def = nullptr, *entry = nullptr;
  std::string analysisContext = "obj_BPF::XdpMd";
  // E022: the ebpf.program `arch` attribute (empty: none) and run-owned group
  // data for the program exporter.
  std::string arch;
  std::string binaryPath; // Build metadata only; never schema or ebpf IR.
  std::shared_ptr<const Payload> payload;
  // Custom-root, run-local finalization after body success. Captures must own
  // their data and must not retain SSA from another program.
  std::function<mlir::LogicalResult(Consumer &)> finalizeBody;
};
struct ReadOrigin;
// Owned, run-local extension data; implementations must not capture short-lived
// SSA.
struct Payload {
  virtual ~Payload() = default;
};
struct CheckedBody : Payload {};
enum class Disposition { Declined, Handled, Error };
template <class T> struct Dispatch {
  Disposition state = Disposition::Declined;
  std::optional<T> value;
  static Dispatch declined() { return {}; }
  static Dispatch handled(T value) {
    return {Disposition::Handled, std::move(value)};
  }
  static Dispatch error() { return {Disposition::Error, std::nullopt}; }
};
struct StatementResult {
  size_t consumed = 1;
};
struct DeclKey {
  std::string receiver, method;
};
struct DeclarationRef {
  enum class Domain { Map, Global, Record, Ring };
  Domain domain = Domain::Map;
  size_t index = 0;
};
struct GlobalDecl {
  mlir::Operation *node = nullptr;
  std::string name, className, section;
  unsigned bits = 64;
  bool isSigned = false, used = false;
  std::shared_ptr<const Payload> payload;
};
struct RecordDecl {
  mlir::Operation *node = nullptr;
  std::string name;
  bool used = false;
  std::shared_ptr<const Payload> layout;
  std::shared_ptr<const record::Layout> recordLayout;
};
struct RingDecl {
  std::string constant, name;
  std::shared_ptr<const record::Layout> layout;
  uint64_t size = 0;
  mlir::Operation *node = nullptr;
  bool used = false;
  mlir::Value value;
};
struct ScopeBinding {
  mlir::Operation *source = nullptr, *analyzed = nullptr;
  mlir::Value value;
};
struct LoopFrame {
  unsigned depth = 0, product = 1;
  ScopeBinding iv;
  std::vector<std::string> carried;
  std::vector<mlir::Value> carriedValues;
  mlir::Block *breakTarget = nullptr, *continueTarget = nullptr;
};
struct CalleePolicy {
  std::string expected;
  bool requireDirect = true;
  // Missing callee may be a shape error handled before invoking this policy.
  bool requireCallee = true;
};
enum class CheckMode { Probe, Check };
struct BodyRequest {
  mlir::Operation *statements = nullptr;
  range::Environment entry;
  math::Interval iv = math::Interval::point(math::Integer::from(0));
  CheckMode mode = CheckMode::Probe;
};
struct BodyResult {
  range::Environment normal;
  std::vector<range::Environment> breaks, nexts;
  std::vector<range::RangeIssue> issues;
  std::shared_ptr<const CheckedBody> checked;
};
using BodyTransfer =
    std::function<llvm::Expected<BodyResult>(Consumer &, const BodyRequest &)>;
// One exported field value: a primitive JSON value, or an owned writer that
// emits exactly one JSON value (an object or array in its own key order — Go
// struct order, which llvm::json::Object cannot keep). The writer is called
// synchronously once from Consumer::json and must capture only owned,
// immutable data (no Consumer or input Operation borrowing).
struct ExportValue {
  std::optional<llvm::json::Value> primitive;
  std::function<void(llvm::json::OStream &)> writer;
  ExportValue(llvm::json::Value value) : primitive(std::move(value)) {}
  static ExportValue write(std::function<void(llvm::json::OStream &)> w) {
    ExportValue out(nullptr);
    out.primitive.reset();
    out.writer = std::move(w);
    return out;
  }
};
using ExportFields = std::vector<std::pair<std::string, ExportValue>>;
using DeclHandler =
    std::function<Dispatch<bool>(Consumer &, mlir::Operation *)>;
using ExprHandler =
    std::function<Dispatch<Expr>(Consumer &, mlir::Operation *)>;
using SourceAuditHandler = std::function<mlir::LogicalResult(
    Consumer &, llvm::ArrayRef<mlir::Operation *>)>;
using EmitHandler =
    std::function<Dispatch<mlir::Value>(Consumer &, const Expr &)>;
using StmtHandler = std::function<Dispatch<StatementResult>(
    Consumer &, llvm::ArrayRef<mlir::Operation *>, size_t, unsigned)>;
using RootHandler =
    std::function<Dispatch<ProgramDecl>(Consumer &, mlir::Operation *)>;
using MapKeyHandler = std::function<Dispatch<Expr>(
    Consumer &, size_t, llvm::ArrayRef<mlir::Operation *>, mlir::Operation *)>;
using MapExportHandler =
    std::function<Dispatch<ExportFields>(Consumer &, size_t, bool)>;
using RecordExportHandler = MapExportHandler;
using GlobalExportHandler = MapExportHandler;
using RingExportHandler = MapExportHandler;
// E022: a handled program export returns every field of the program object in
// Go's schemaProgram order (schema.go:91-105); declined keeps the common five.
using ProgramExportHandler = MapExportHandler;
// E022: one top-level `core` value at a fixed position (only kernel_types,
// first in core — schema.go:156-178); declined omits the key.
using CoreExportHandler =
    std::function<Dispatch<ExportValue>(Consumer &, bool)>;
using UnusedDiagnosticHandler =
    std::function<Dispatch<bool>(Consumer &, DeclarationRef)>;
using RMWExemptionHandler =
    std::function<bool(const Consumer &, const ReadOrigin &, size_t)>;
struct PacketLoopHooks;
struct PacketSubprogramHooks;
struct UprobeHooks;
struct Registry {
  std::shared_ptr<PacketLoopHooks> packetLoop;
  std::shared_ptr<PacketSubprogramHooks> packetSubprogram;
  std::shared_ptr<UprobeHooks> uprobe;
  std::vector<std::pair<DeclKey, DeclHandler>> declarations;
  std::vector<std::pair<std::string, ExprHandler>> expressions;
  std::vector<DeclHandler> operatorChecks;
  std::vector<DeclHandler> rejectOnlyScalarChecks;
  std::vector<SourceAuditHandler> sourceAudits;
  std::vector<std::pair<std::string, EmitHandler>> emitters;
  std::vector<std::pair<std::string, StmtHandler>> statements;
  std::vector<std::pair<std::string, RootHandler>> roots;
  std::vector<std::pair<std::string, MapKeyHandler>> mapKeys;
  std::vector<std::pair<std::string, MapExportHandler>> mapExporters;
  std::vector<RecordExportHandler> recordExporters;
  std::vector<RingExportHandler> ringExporters;
  std::vector<GlobalExportHandler> globalExporters;
  std::vector<UnusedDiagnosticHandler> unusedDiagnostics;
  std::vector<RMWExemptionHandler> rmwExemptions;
  std::vector<std::pair<std::string, ProgramExportHandler>> programExporters;
  std::vector<std::pair<std::string, CoreExportHandler>> coreExporters;
  bool valid = true;
  void addProgramExporter(llvm::StringRef kind, ProgramExportHandler h) {
    programExporters.emplace_back(kind.str(), std::move(h));
  }
  // Only keys of the fixed core table are accepted; others invalidate.
  bool addCoreExporter(llvm::StringRef key, CoreExportHandler h);
  void addDeclaration(DeclKey key, DeclHandler h) {
    declarations.emplace_back(std::move(key), std::move(h));
  }
  void addExpression(llvm::StringRef key, ExprHandler h) {
    expressions.emplace_back(key.str(), std::move(h));
  }
  bool addEmitter(llvm::StringRef key, EmitHandler h);
  void addStatement(llvm::StringRef key, StmtHandler h) {
    statements.emplace_back(key.str(), std::move(h));
  }
  void addRoot(llvm::StringRef key, RootHandler h) {
    roots.emplace_back(key.str(), std::move(h));
  }
  void addMapKey(llvm::StringRef key, MapKeyHandler h) {
    mapKeys.emplace_back(key.str(), std::move(h));
  }
  void addMapExporter(llvm::StringRef key, MapExportHandler h) {
    mapExporters.emplace_back(key.str(), std::move(h));
  }
  void addRecordExporter(RecordExportHandler h) {
    recordExporters.push_back(std::move(h));
  }
  void addRingExporter(RingExportHandler h) {
    ringExporters.push_back(std::move(h));
  }
  void addGlobalExporter(GlobalExportHandler h) {
    globalExporters.push_back(std::move(h));
  }
  void addUnusedDiagnostic(UnusedDiagnosticHandler h) {
    unusedDiagnostics.push_back(std::move(h));
  }
  void addRMWExemption(RMWExemptionHandler h) {
    rmwExemptions.push_back(std::move(h));
  }
};
struct ScopeState;
void registerConsumerGroups(Registry &);
class ScopeGuard {
  Consumer &consumer;
  std::unique_ptr<ScopeState> saved;

public:
  explicit ScopeGuard(Consumer &);
  ~ScopeGuard();
  ScopeGuard(const ScopeGuard &) = delete;
  void commit();
};
} // namespace spinel::consumer
