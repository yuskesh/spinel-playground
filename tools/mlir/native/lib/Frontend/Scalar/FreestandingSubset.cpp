// Native fs_subset_check runs before importing: both can reject allocating syntax, but order
// determines the first user-visible cause. n.times { |i| i } then explains why a block is not
// freestanding instead of generic unsupported-node CallNode. In the original eight-row subset
// corpus only this row changed first cause; seven others named the same kind with different
// wording. Match frozen Ast.subtree exactly: last-in-first-out stack, pushing children in field
// order and popping in reverse. Reordering changes diagnostics; do not redesign by intuition.

#include "FreestandingSubset.h"

#include "spinel-mlir/Contract/Model.h"
#include "spinel-mlir/Core/BlockLoops.h"
#include "spinel-mlir/Core/SubsetRefusals.h"
#include "spinel-mlir/Scalar/Importer.h"

#include <map>
#include <set>

#include "llvm/ADT/SmallVector.h"
#include <vector>

using namespace spinel_mlir;
using contract::AstField;
using contract::Node;

namespace {

const AstField *findField(const Node &n, llvm::StringRef key) {
  for (const AstField &f : n.fields)
    if (f.key == key)
      return &f;
  return nullptr;
}

int64_t refOf(const Node &n, llvm::StringRef key) {
  const AstField *f = findField(n, key);
  if (!f || f->kind != AstField::Kind::Reference)
    return -1;
  return std::get<int64_t>(f->value);
}

std::vector<int64_t> arrOf(const Node &n, llvm::StringRef key) {
  const AstField *f = findField(n, key);
  if (!f || f->kind != AstField::Kind::Array)
    return {};
  return std::get<std::vector<int64_t>>(f->value);
}

std::string strOf(const Node &n, llvm::StringRef key) {
  const AstField *f = findField(n, key);
  if (!f || f->kind != AstField::Kind::String)
    return {};
  return std::get<std::string>(f->value);
}

} // namespace

namespace spinel_mlir::scalar {

std::vector<const Node *> fsSubtree(const FsNodeLookup &lookup,
                                    const Node &root) {
  // Frozen Ast.subtree pops the stack end: push fields and array elements in order, then visit in
  // reverse.
  std::vector<const Node *> out;
  std::vector<const Node *> stack{&root};
  while (!stack.empty()) {
    const Node *cur = stack.back();
    stack.pop_back();
    if (!cur)
      continue;
    out.push_back(cur);
    // Push in producer order, not the model dictionary key order. With a last-in-first-out
    // traversal, this determines the first refused node.
    llvm::SmallVector<const AstField *, 12> fields;
    for (const AstField &f : cur->fields)
      fields.push_back(&f);
    llvm::sort(fields, [](const AstField *a, const AstField *b) {
      return a->producerOrder < b->producerOrder;
    });
    for (const AstField *f : fields) {
      if (f->kind == AstField::Kind::Reference) {
        const int64_t id = std::get<int64_t>(f->value);
        if (id >= 0)
          stack.push_back(lookup(id));
      } else if (f->kind == AstField::Kind::Array) {
        for (int64_t id : std::get<std::vector<int64_t>>(f->value))
          stack.push_back(lookup(id));
      }
    }
  }
  return out;
}

// Frozen fs_excused_arrays: ArrayNode in MultiWriteNode value for a, b = b, a % b does not
// allocate; parallel assignment handles it. Excuse this position, not the entire kind.
static std::set<int64_t> excusedArrays(const FsNodeLookup &lookup,
                                       const Node &def) {
  std::set<int64_t> out;
  for (const Node *n : fsSubtree(lookup, def)) {
    if (n->kind != "MultiWriteNode")
      continue;
    const int64_t v = refOf(*n, "value");
    const Node *value = v >= 0 ? lookup(v) : nullptr;
    if (value && value->kind == "ArrayNode")
      out.insert(value->id);
  }
  return out;
}

// Frozen fs_excused_indexing admits []/[]= only on declared buffers and propagates through excused
// two-argument views. Without propagation, buf[a, b][c, d] reports heap allocation rather than the
// view-specific refusal.
static std::set<int64_t> excusedIndexing(const FsNodeLookup &lookup,
                                         const Node &def,
                                         const std::set<std::string> &bufnames) {
  std::set<int64_t> out;
  if (bufnames.empty())
    return out;
  std::vector<const Node *> subs;
  std::map<int64_t, size_t> nargs;
  for (const Node *n : fsSubtree(lookup, def)) {
    if (n->kind != "CallNode")
      continue;
    const std::string name = strOf(*n, "name");
    if (name != "[]" && name != "[]=")
      continue;
    subs.push_back(n);
    const int64_t a = refOf(*n, "arguments");
    const Node *args = a >= 0 ? lookup(a) : nullptr;
    nargs[n->id] = args ? arrOf(*args, "arguments").size() : 0;
  }
  for (const Node *n : subs) {
    const int64_t r = refOf(*n, "receiver");
    const Node *recv = r >= 0 ? lookup(r) : nullptr;
    if (!recv)
      continue;
    if (recv->kind == "LocalVariableReadNode" &&
        bufnames.count(strOf(*recv, "name")))
      out.insert(n->id);
  }
  bool changed = true;
  while (changed) {
    changed = false;
    for (const Node *n : subs) {
      if (out.count(n->id))
        continue;
      const int64_t r = refOf(*n, "receiver");
      const Node *recv = r >= 0 ? lookup(r) : nullptr;
      if (recv && out.count(recv->id) && nargs[recv->id] == 2) {
        out.insert(n->id);
        changed = true;
      }
    }
  }
  return out;
}

std::optional<std::string> fsSubsetCheck(const FsNodeLookup &lookup,
                                         const FsTypeLookup &typeOf,
                                         const Node &def,
                                         llvm::StringRef name,
                                         const ScalarRootDesc *decl,
                                         const std::set<std::string> &lent) {
  std::set<int64_t> excused = excusedArrays(lookup, def);
  // Decision 0044: a buffer lent to this helper is indexed as a declared one.
  std::set<std::string> bufnames(lent.begin(), lent.end());
  if (decl) {
    const int64_t p = refOf(def, "parameters");
    const Node *params = p >= 0 ? lookup(p) : nullptr;
    std::vector<std::string> pnames;
    if (params)
      for (int64_t id : arrOf(*params, "requireds"))
        if (const Node *q = lookup(id))
          pnames.push_back(strOf(*q, "name"));
    for (size_t i = 0; i < decl->params.size() && i < pnames.size(); ++i)
      if (decl->params[i].kind == ScalarParamDesc::Kind::Buffer)
        bufnames.insert(pnames[i]);
  }
  const std::set<int64_t> idx = excusedIndexing(lookup, def, bufnames);
  excused.insert(idx.begin(), idx.end());
  // DECISION 0041 stage 1: a loop with a literal block is excused by position
  // (the call, its BlockNode and its parameter nodes); its receiver, limit and
  // body are walked as any other code. A block call that is not such a loop
  // keeps its refusal, with the reason BlockLoops.cpp gives where the call is
  // one of the five names.
  std::map<int64_t, std::string> blockRefusals;
  for (const Node *n : fsSubtree(lookup, def)) {
    core::BlockLoopShape shape = core::classifyBlockLoop(*n, lookup);
    if (shape.loop) {
      using K = core::BlockLoop::Kind;
      if (shape.loop->kind == K::Each || shape.loop->kind == K::EachWithIndex) {
        const Node *recv = lookup(shape.loop->receiver);
        if (!recv || recv->kind != "LocalVariableReadNode" ||
            !bufnames.count(strOf(*recv, "name"))) {
          blockRefusals[n->id] =
              "`" + core::blockLoopName(shape.loop->kind).str() +
              "` is a loop only on a declared buffer parameter; this receiver "
              "is not one (decision 0041)";
          continue;
        }
      }
      excused.insert(n->id);
      excused.insert(shape.loop->structural.begin(), shape.loop->structural.end());
    } else if (shape.refusal) {
      const std::string callee = strOf(*n, "name");
      if (callee == "times" || callee == "upto" || callee == "downto" ||
          callee == "each" || callee == "each_with_index")
        blockRefusals[n->id] = *shape.refusal;
    }
  }

  for (const Node *n : fsSubtree(lookup, def)) {
    if (n == &def || excused.count(n->id))
      continue;
    if (auto refused = blockRefusals.find(n->id); refused != blockRefusals.end())
      return (name + ": " + refused->second).str();
    // Decision 0026 step 5: the owned table first, then the inherited list.
    // No kind is in both (tests/subset-tables/check.rb).
    const std::string *reason = nullptr;
    auto owned = core::subsetRefusalNodes().find(n->kind);
    if (owned != core::subsetRefusalNodes().end())
      reason = &owned->second.reason;
    else if (auto inherited = fsInheritedNodes().find(n->kind);
             inherited != fsInheritedNodes().end())
      reason = &inherited->second;
    if (reason)
      return (name + ": " + n->kind + " is not in the freestanding subset -- " +
              *reason +
              ". (P003 D-3: the freestanding subset is the ALLOCATION-FREE "
              "subset; see docs/plan/P003_freestanding_backend_roadmap.md)")
          .str();
    if (n->kind == "CallNode") {
      const std::string callee = strOf(*n, "name");
      auto call = core::subsetRefusalCalls().find(callee);
      // Decision 0042 stage 2: on a receiver the reader types Integer, `<<`
      // is Integer#<<, a shift, which Spinel compiles to `sp_int_shl` by the
      // same type. Any other receiver keeps the row's refusal.
      const int64_t receiver = refOf(*n, "receiver");
      if (callee == "<<" && receiver >= 0 && typeOf(receiver) == "int")
        continue;
      // Stage 3: `**` on two operands the reader types Integer is
      // Integer#**, which is exact or fails at the declared width. Any other
      // operand keeps the row's refusal.
      if (callee == "**" && receiver >= 0 && typeOf(receiver) == "int") {
        const int64_t argsId = refOf(*n, "arguments");
        const Node *argsNode = argsId >= 0 ? lookup(argsId) : nullptr;
        const std::vector<int64_t> powArgs =
            argsNode ? arrOf(*argsNode, "arguments") : std::vector<int64_t>{};
        if (powArgs.size() == 1 && typeOf(powArgs[0]) == "int")
          continue;
      }
      if (call != core::subsetRefusalCalls().end())
        return (name + ": " + call->second).str();
    }
  }
  return std::nullopt;
}

} // namespace spinel_mlir::scalar
