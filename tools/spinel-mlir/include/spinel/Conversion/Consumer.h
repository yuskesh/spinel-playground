#pragma once
#include "mlir/IR/Builders.h"
#include "spinel/Analysis/GroupARange.h"
#include "spinel/Conversion/ConsumerExtensions.h"
#include "spinel/Conversion/LowerToEBPF.h"
#include "spinel/Dialect/SpinelFacts/IR/SpinelFactsDialect.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/DenseSet.h"
#include "llvm/Support/JSON.h"
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <vector>
namespace spinel::consumer {
using namespace mlir;
StringRef text(Operation *, StringRef);
StringRef field(Operation *, StringRef, StringRef);
Location outputLoc(Operation *);
struct MapDecl {
  Operation *node = nullptr;
  std::string name;
  unsigned bits = 64;
  bool isSigned = false;
  int64_t entries = 0;
  Value value;
  bool used = false;
  std::string kind = "array", className = "ArrayMap";
  unsigned keyBits = 32;
  bool keySigned = false;
  uint64_t flags = 0;
  std::string keyRecord, valueRecord, eventRecord;
  std::shared_ptr<const Payload> payload;
  Type keyType, valueType, mapType;
};
struct ReadOrigin {
  size_t map = 0;
  std::optional<int64_t> key;
  std::string ref;
  enum class Domain { Map, Global, Parameter, CallResult };
  Domain domain = Domain::Map;
  int64_t token = -1;
};
struct ScalarExpr {
  Operation *node = nullptr;
  std::string kind, op, name, divMode;
  int64_t literal = 0;
  size_t map = 0;
  range::RangeValue range;
  std::vector<ReadOrigin> reads;
  std::vector<std::shared_ptr<ScalarExpr>> args;
  std::shared_ptr<const Payload> payload;
  bool typedMapKey = false;
};
using Expr = std::shared_ptr<ScalarExpr>;
struct Local {
  Expr expr;
  Value value;
};
struct Borrow {
  size_t map = 0;
  std::optional<int64_t> key;
  Value value;
};
using Locals = std::map<std::string, Local>;
struct SubprogramState;
class Consumer {
public:
  std::shared_ptr<SubprogramState> subprograms;
  Registry registry;
  BodyTransfer bodyTransfer;
  std::vector<GlobalDecl> globals;
  std::vector<RecordDecl> records;
  // Go usedRecords order, independent of RecordDecl::used. E029 appends rings.
  std::vector<size_t> usedRecordOrder() const;
  std::vector<RingDecl> rings;
  std::set<std::string> badRings;
  std::set<std::string> badRecords;
  // Only an explicitly diagnosed dependency may continue without a new SB.
  std::set<int64_t> dependentDeclarationErrors;
  std::vector<DeclarationRef> declarationOrder;
  range::Environment environment;
  std::vector<LoopFrame> frames;
  std::map<std::string, ScopeBinding> bindings;
  llvm::DenseMap<Operation *, Operation *> parents;
  Operation *activeDef = nullptr;
  std::string activeKind = "xdp";
  Value contextValue;
  bool blocking = false, probing = false;
  // Rejections actually printed this run; ScopeGuard never restores it (E028).
  size_t printedRejections = 0;
  std::vector<range::RangeIssue> probeIssues;
  Operation *parent(Operation *node) const;
  LogicalResult known(Operation *node, const CalleePolicy &);
  Dispatch<Expr> dispatchExpression(StringRef kind, Operation *);
  Dispatch<Value> dispatchEmitter(StringRef kind, const Expr &);
  Dispatch<StatementResult> dispatchStatement(StringRef kind,
                                              llvm::ArrayRef<Operation *>,
                                              size_t, unsigned);
  Dispatch<bool> dispatchDeclaration(Operation *);
  Dispatch<ProgramDecl> dispatchRoot(Operation *);
  Dispatch<Expr> dispatchMapKey(size_t, llvm::ArrayRef<Operation *>,
                                Operation *);
  Dispatch<ExportFields> dispatchExport(DeclarationRef, bool);
  Dispatch<ExportFields> dispatchProgramExport(size_t program, bool schema);
  Dispatch<ExportValue> dispatchCoreExport(StringRef key, bool schema);
  llvm::Expected<BodyResult> transferBody(const BodyRequest &);
  bool rmwExempt(const ReadOrigin &, size_t) const;
  LogicalResult knownMap(Operation *, size_t);
  FailureOr<Expr> checkedMapKey(size_t, llvm::ArrayRef<Operation *>,
                                Operation *);
  Value emitMapKey(const Expr &, size_t);

  ModuleOp input;
  MLIRContext *ctx;
  OpBuilder builder;
  llvm::DenseMap<int64_t, Operation *> nodes, analyzed;
  llvm::DenseMap<int64_t, SmallVector<Operation *>> types, evidence;
  std::string mapName, programName;

  std::vector<MapDecl> maps;

  std::vector<ProgramDecl> programs;
  // Selected source roots remain BPF-side even when their body is rejected.
  SmallVector<Operation *> rootEntries;
  // Source-level lookup names outlive a present arm's Borrow/SSA. Probe never
  // publishes names; each root/subprogram definition has its own history.
  std::map<Operation *, std::set<std::string>> lookupBindingNames;
  // Fixed from the complete selected root set before analyzing any body.
  bool allRootsXdp = false;
  int64_t entries = 0;
  Value mapValue;
  bool usedMap = false;

  explicit Consumer(ModuleOp module);

  // Test setup only, before run/dispatch: replace all production registrations
  // with an independently owned registry. This does not reset consumer state.
  void useIsolatedRegistryForTesting(Registry fresh = {}) {
    registry = std::move(fresh);
  }

  LogicalResult diagnostic(Operation *node, StringRef code, StringRef name,
                           StringRef message, bool withPath = false);
  LogicalResult unknownDiagnostic(Operation *node, StringRef code, StringRef name,
                                  StringRef message, bool withPath = false);
  LogicalResult recordLocatedDiagnostic(const inspection::Diagnostic &);
  LogicalResult recordDiagnostic(Operation *node, StringRef code, StringRef name,
                                 StringRef message, bool unknown,
                                 std::optional<std::string> path);
  // An explicit `[path: a -> b]`; withPath above uses activeDiagnosticPath
  // when it is set and programName otherwise.
  LogicalResult diagnosticWithPath(Operation *node, StringRef code,
                                   StringRef name, StringRef message,
                                   llvm::ArrayRef<std::string> path);
  std::vector<std::string> activeDiagnosticPath;

  // Go's membership (analyze.go membership): top-level defs of the root file
  // and the sides ("user" / "bpf") that reach them through codegen callees.
  // Reads the analyzed table only; facts are not consumed.
  struct UserSideMembership {
    std::map<std::string, Operation *> defs;
    std::map<std::string, std::set<std::string>> sides;
    std::vector<Operation *> topStatements;
    std::vector<inspection::Edge> edges;
  };
  FailureOr<UserSideMembership> userSideMembership(llvm::ArrayRef<Operation *> roots = {});
  Inspection *inspectionOutput = nullptr;
  bool inspectionGraphAvailable = false;
  bool inspectionLiteralRejected = false;
  llvm::DenseMap<Operation *,Operation *> inspectionRootDefinitions;
  Operation *inspectionRootDefinition = nullptr;
  void noteInspectionBody(Operation *);
  inspection::Domain inspectionDomain;
  inspection::Diagnostic domainDiagnostic(Operation *, StringRef verdict, StringRef code,
      StringRef name, StringRef message, std::optional<std::string> path = std::nullopt);
  void snapshotDomainGraph(llvm::ArrayRef<Operation *> roots = {});
  void finishInspection(bool success);
  std::string exportRecords();
  std::vector<UprobeTarget> exportUprobeTargets();
  // `file:line:col: <verdict> <code> (<name>): <message>[ [path: …]]`, the
  // one rendering shared by rejections and conditional diagnostics.
  std::string renderDiagnostic(Operation *node, StringRef verdict,
                               StringRef code, StringRef name,
                               StringRef message,
                               std::optional<std::string> path = std::nullopt);
  enum class DiagnosticVerdict { Conditional, Rejected, Unknown };
  struct PendingDiagnostic {
    unsigned line = 0, col = 0;
    std::string text; // rendered, without the success-path warning prefix
    std::string rejectedCode; // Only actual rejections, never Probe/conditional.
    DiagnosticVerdict verdict = DiagnosticVerdict::Conditional;
    std::string code; // Structured identity, including Unknown (not recovery).
    std::optional<inspection::Diagnostic> domain;
  };
  // Run-wide final failure mark: never rolled back by ScopeGuard. Subprogram
  // analysis must not finalize partial call sites when this is set.
  bool programBodyRejected = false;
  // E052: only a newly recorded source-audit Unknown SB016 enables the
  // prescribed continuation. Run-wide, never restored by ScopeGuard.
  bool sourceAuditUnknown = false;
  LogicalResult recoverRejectedProgram(StringRef rejectedCode);
  // E034: a rejected data declaration is retained across local dispatches.
  // Recovery only skips uses of absent failed resources, never creates values.
  bool declarationRecovery = false;
  std::set<std::string> failedDataDeclarations;
  llvm::DenseSet<int64_t> recoverySkipped;
  std::vector<PendingDiagnostic> *runDiagnostics = nullptr;
  std::vector<PendingDiagnostic> pendingConditionals;
  void conditionalDiagnostic(Operation *, StringRef code, StringRef name,
                             StringRef message);
  void prepareDeclarationRecovery(Operation *body);
  // SB003 (CrossDomainUse): defs reached from both sides and eBPF-only API
  // calls on the user side. run() prints them with the conditional
  // diagnostics in position order (Go's rejected listing).
  FailureOr<std::vector<PendingDiagnostic>> userSideFindings();

  LogicalResult error(Operation *node, StringRef message);

  bool isProducer() const;

  StringRef spelling(Operation *node, bool symbol);

  int64_t id(Operation *node);

  Operation *ref(Operation *node, StringRef key);

  SmallVector<Operation *> array(Operation *node, StringRef key);

  SmallVector<Operation *> args(Operation *node);

  std::string constant(Operation *node, unsigned depth = 0);

  SmallVector<Operation *> selectedTop;
  LogicalResult checkTree(Operation *node, llvm::DenseSet<int64_t> &seen,
                          bool root = true);

  LogicalResult select(Operation *root);

  LogicalResult known(Operation *node, bool call = false);
  // Semantic value/callee check; identity-only declarations still use known.
  LogicalResult typed(Operation *node);
  LogicalResult checkScalarShape(Operation *node);

  std::string equivalenceFailure;
  bool equivalentNode(Operation *pristine, Operation *target,
                      unsigned depth = 0);

  FailureOr<int64_t> integer(Operation *node);

  FailureOr<Value> key(Operation *node, int64_t *literal = nullptr);

  LogicalResult mapCall(Operation *node);

  LogicalResult body(Operation *statements, StringRef borrowedName = {},
                     Value borrowed = {}, int64_t borrowedKey = -1,
                     unsigned depth = 0);

  // Checked scalar expressions carry mathematical ranges and provenance
  // independently of the values emitted by the typed ebpf/arith builders.

  Locals locals;
  std::map<std::string, Borrow> borrows;
  range::MapType rangeMap(size_t index);

  LogicalResult rangeFailure(llvm::Error failure, Operation *node);

  LogicalResult issue(const range::RangeIssue &i);

  LogicalResult checked(range::Check check, Operation *node);

  FailureOr<Expr> outcome(Expr result,
                          llvm::Expected<range::RangeOutcome> value);

  bool hasMapOperation(Operation *node);

  FailureOr<Expr> scalar(Operation *node);

  Value emitScalar(const Expr &e);

  Value scalarKey(const Expr &e);

  Value scalarStore(const Expr &e, size_t map);

  // Check read origins before evaluating the numeric value expression.
  std::vector<ReadOrigin> origins(Operation *node);

  LogicalResult rmwFirst(Operation *call, Operation *keyNode, Operation *value,
                         size_t map, bool update);

  LogicalResult scalarBody(Operation *statements, unsigned depth = 0);
  // Narrow checked local ranges only; preserve SSA values and provenance.
  LogicalResult refineLocals(const Expr &predicate, bool positive);

  LogicalResult scalarStatements(llvm::ArrayRef<Operation *> statements,
                                 unsigned depth = 0);

  LogicalResult scalarBranch(Operation *node, Value condition,
                             const Expr &predicate,
                             std::optional<Borrow> borrow,
                             const std::string &name, unsigned depth,
                             Operation *binding = nullptr);

  std::string json(bool schema);

  FailureOr<Artifacts> run();
};
} // namespace spinel::consumer
