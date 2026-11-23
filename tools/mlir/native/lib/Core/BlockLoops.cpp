//===- BlockLoops.cpp - literal blocks on iterator calls ------------------===//
//
// Decision 0041, stage 1. See BlockLoops.h.
//
//===----------------------------------------------------------------------===//
#include "spinel-mlir/Core/BlockLoops.h"
#include "spinel-mlir/Core/Intrinsics.h"

#include <algorithm>
#include <set>
#include <variant>

namespace spinel_mlir::core {

using contract::AstField;
using contract::Node;

namespace {

const AstField *field(const Node &n, llvm::StringRef key) {
  for (const AstField &f : n.fields)
    if (f.key == key) return &f;
  return nullptr;
}

int64_t ref(const Node &n, llvm::StringRef key) {
  const AstField *f = field(n, key);
  if (!f || f->kind != AstField::Kind::Reference) return -1;
  return std::get<int64_t>(f->value);
}

std::vector<int64_t> array(const Node &n, llvm::StringRef key) {
  const AstField *f = field(n, key);
  if (!f || f->kind != AstField::Kind::Array) return {};
  return std::get<std::vector<int64_t>>(f->value);
}

std::string str(const Node &n, llvm::StringRef key) {
  const AstField *f = field(n, key);
  if (!f || f->kind != AstField::Kind::String) return {};
  return std::get<std::string>(f->value);
}

std::optional<int64_t> integer(const Node &n, llvm::StringRef key) {
  const AstField *f = field(n, key);
  if (!f || f->kind != AstField::Kind::Integer) return std::nullopt;
  return std::get<int64_t>(f->value);
}

bool isPosition(llvm::StringRef key) {
  return key == "node_line" || key == "node_col" || key == "node_file";
}

/// A field outside `keys` (positions apart). A producer that writes a new
/// field may be saying something this rule has not read, so the shape is
/// refused rather than guessed at.
std::optional<std::string> unknownField(const Node &n,
                                        std::initializer_list<llvm::StringRef> keys) {
  for (const AstField &f : n.fields) {
    if (isPosition(f.key)) continue;
    bool known = false;
    for (llvm::StringRef k : keys) known = known || f.key == k;
    if (!known) return n.kind + "." + f.key;
  }
  return std::nullopt;
}

std::vector<std::string> splitNames(const std::string &text) {
  std::vector<std::string> out;
  std::string cur;
  for (char c : text) {
    if (c == ',') {
      if (!cur.empty()) out.push_back(cur);
      cur.clear();
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

std::optional<BlockLoop::Kind> kindOf(llvm::StringRef name) {
  if (name == "times") return BlockLoop::Kind::Times;
  if (name == "upto") return BlockLoop::Kind::Upto;
  if (name == "downto") return BlockLoop::Kind::Downto;
  if (name == "each") return BlockLoop::Kind::Each;
  if (name == "each_with_index") return BlockLoop::Kind::EachWithIndex;
  return std::nullopt;
}

} // namespace

llvm::StringRef blockLoopName(BlockLoop::Kind kind) {
  switch (kind) {
  case BlockLoop::Kind::Times: return "times";
  case BlockLoop::Kind::Upto: return "upto";
  case BlockLoop::Kind::Downto: return "downto";
  case BlockLoop::Kind::Each: return "each";
  case BlockLoop::Kind::EachWithIndex: return "each_with_index";
  }
  return "";
}

unsigned blockLoopYields(BlockLoop::Kind kind) {
  return kind == BlockLoop::Kind::EachWithIndex ? 2 : 1;
}

BlockLoopShape classifyBlockLoop(const Node &call, BlockLoopLookup lookup) {
  BlockLoopShape out;
  if (call.kind != "CallNode") return out;
  const int64_t blockId = ref(call, "block");
  if (blockId < 0) return out;
  const Node *block = lookup(blockId);
  const std::string name = str(call, "name");
  // A word intrinsic (decision 0022) with a block keeps the refusal its own
  // recognition rule gives, as it had before this classifier existed.
  if (ref(call, "receiver") < 0 && coreIntrinsic(name)) return out;
  auto refuse = [&](const std::string &why) {
    out.refusal = why;
    return out;
  };
  if (!block) return refuse("`" + name + "`: its block is missing from the analysis");
  if (block->kind == "BlockArgumentNode")
    return refuse("`" + name +
                  "` with a block argument (`&block` or `&:name`): a block is "
                  "admitted only as a literal `{ ... }` or `do ... end` on "
                  "`times`, `upto`, `downto`, `each` and `each_with_index` "
                  "(decision 0041)");
  if (block->kind != "BlockNode")
    return refuse("`" + name + "` with a " + block->kind);
  if (auto sym = integer(*block, "sym_proc_block"); sym && *sym != 0)
    return refuse("`" + name +
                  "(&:name)`: a block argument is not admitted; write the "
                  "block out as `{ |x| ... }` (decision 0041)");
  const int64_t receiver = ref(call, "receiver");
  if (receiver < 0)
    return refuse("`" + name +
                  "` with a block and no receiver: a method of the program "
                  "that yields to a block is not in this subset (decision "
                  "0041)");
  const std::optional<BlockLoop::Kind> kind = kindOf(name);
  if (!kind)
    return refuse("`" + name +
                  "` with a block: only `times`, `upto`, `downto`, `each` and "
                  "`each_with_index` take a literal block in this subset "
                  "(decision 0041)");
  if (auto bad = unknownField(*block, {"locals", "parameters", "body",
                                       "sym_proc_block"}))
    return refuse("`" + name + "`'s block has the field " + *bad +
                  ", which this rule has not read");

  BlockLoop loop;
  loop.kind = *kind;
  loop.call = call.id;
  loop.receiver = receiver;
  loop.block = blockId;
  loop.body = ref(*block, "body");
  loop.structural.push_back(blockId);

  // The arguments: one limit for `upto` and `downto`, none for the others.
  const unsigned wantArgs =
      (*kind == BlockLoop::Kind::Upto || *kind == BlockLoop::Kind::Downto) ? 1 : 0;
  std::vector<int64_t> args;
  const int64_t argumentsId = ref(call, "arguments");
  if (argumentsId >= 0) {
    const Node *a = lookup(argumentsId);
    if (!a || a->kind != "ArgumentsNode")
      return refuse("`" + name + "` with arguments of an unexpected form");
    args = array(*a, "arguments");
    loop.structural.push_back(argumentsId);
  }
  if (args.size() != wantArgs)
    return refuse("`" + name + "` takes " + std::to_string(wantArgs) +
                  " argument(s) here, and is given " +
                  std::to_string(args.size()));
  if (wantArgs) {
    const Node *limit = lookup(args[0]);
    if (!limit || limit->kind == "SplatNode" || limit->kind == "BlockArgumentNode" ||
        limit->kind == "KeywordHashNode")
      return refuse("`" + name + "` takes one plain Integer argument");
    loop.limit = args[0];
  }

  // The parameters: plain required names, at most what the call yields.
  const int64_t paramsId = ref(*block, "parameters");
  if (paramsId >= 0) {
    const Node *bp = lookup(paramsId);
    if (!bp)
      return refuse("`" + name + "`'s block parameters are missing from the analysis");
    if (bp->kind == "NumberedParametersNode" || bp->kind == "ItParametersNode")
      return refuse("`" + name +
                    "` with a numbered or `it` parameter: name the block's "
                    "parameter, as in `{ |i| ... }` (decision 0041)");
    if (bp->kind != "BlockParametersNode")
      return refuse("`" + name + "`'s block parameters are a " + bp->kind);
    if (auto bad = unknownField(*bp, {"parameters", "locals"}))
      return refuse("`" + name + "`'s block has the field " + *bad +
                    ", which this rule has not read");
    if (!array(*bp, "locals").empty())
      return refuse("`" + name +
                    "` with block-local variables (`|x; y|`): a variable "
                    "first assigned in the block is already the block's own");
    loop.structural.push_back(paramsId);
    const int64_t plistId = ref(*bp, "parameters");
    if (plistId >= 0) {
      const Node *plist = lookup(plistId);
      if (!plist || plist->kind != "ParametersNode")
        return refuse("`" + name + "`'s block parameters are of an unexpected form");
      if (!array(*plist, "optionals").empty() || !array(*plist, "keywords").empty() ||
          !array(*plist, "posts").empty() || ref(*plist, "rest") >= 0 ||
          ref(*plist, "keyword_rest") >= 0 || ref(*plist, "block") >= 0)
        return refuse("`" + name +
                      "`'s block takes optional, splat, keyword or block "
                      "parameters; only plain names are in this subset");
      if (auto bad = unknownField(*plist, {"requireds", "optionals", "keywords",
                                           "posts", "rest", "keyword_rest",
                                           "block"}))
        return refuse("`" + name + "`'s block has the field " + *bad +
                      ", which this rule has not read");
      loop.structural.push_back(plistId);
      for (int64_t id : array(*plist, "requireds")) {
        const Node *p = lookup(id);
        if (!p || p->kind != "RequiredParameterNode")
          return refuse("`" + name +
                        "`'s block destructures a parameter; only plain names "
                        "are in this subset");
        if (auto flags = integer(*p, "flags"); flags && *flags != 0)
          return refuse("`" + name + "`'s block repeats a parameter name");
        if (auto bad = unknownField(*p, {"name", "flags"}))
          return refuse("`" + name + "`'s block has the field " + *bad +
                        ", which this rule has not read");
        loop.params.push_back(str(*p, "name"));
        loop.paramNodes.push_back(id);
        loop.structural.push_back(id);
      }
    }
  }
  if (loop.params.size() > blockLoopYields(*kind))
    return refuse("`" + name + "` yields " +
                  std::to_string(blockLoopYields(*kind)) +
                  " value(s), and its block names " +
                  std::to_string(loop.params.size()) +
                  " parameters; Ruby would bind the others to nil, which is "
                  "not in this subset");
  {
    const std::set<std::string> named(loop.params.begin(), loop.params.end());
    for (const std::string &l : splitNames(str(*block, "locals")))
      if (!named.count(l)) loop.locals.push_back(l);
  }
  out.loop = std::move(loop);
  return out;
}

namespace {

/// One pass over a method, keeping the stack of enclosing scopes: the method
/// and each admitted loop's block. A local node with `depth` d belongs to
/// the scope d levels up.
struct ShadowWalk {
  BlockLoopLookup lookup;
  std::vector<std::set<std::string>> owned; // per scope, the names it owns
  std::vector<size_t> parent;               // per scope, its enclosing scope
  struct Param {
    size_t scope;
    std::string name;
    int64_t node;
  };
  std::vector<Param> params;
  std::set<int64_t> seen;

  void walk(int64_t id, std::vector<size_t> &stack) {
    if (id < 0 || !seen.insert(id).second) return;
    const Node *n = lookup(id);
    if (!n) return;
    if (llvm::StringRef(n->kind).starts_with("LocalVariable")) {
      const std::optional<int64_t> depth = integer(*n, "depth");
      const size_t d = depth && *depth >= 0 ? static_cast<size_t>(*depth) : 0;
      if (d < stack.size()) owned[stack[stack.size() - 1 - d]].insert(str(*n, "name"));
    }
    if (n->kind == "CallNode") {
      BlockLoopShape shape = classifyBlockLoop(*n, lookup);
      if (shape.loop) {
        const BlockLoop &loop = *shape.loop;
        walk(loop.receiver, stack);
        walk(loop.limit, stack);
        const size_t scope = owned.size();
        owned.emplace_back(loop.params.begin(), loop.params.end());
        parent.push_back(stack.back());
        for (size_t i = 0; i < loop.params.size(); ++i)
          params.push_back({scope, loop.params[i], loop.paramNodes[i]});
        for (const std::string &l : loop.locals) {
          owned[scope].insert(l);
          params.push_back({scope, l, loop.block});
        }
        for (int64_t s : loop.structural) seen.insert(s);
        stack.push_back(scope);
        walk(loop.body, stack);
        stack.pop_back();
        return;
      }
    }
    for (const AstField &f : n->fields) {
      if (f.kind == AstField::Kind::Reference)
        walk(std::get<int64_t>(f.value), stack);
      else if (f.kind == AstField::Kind::Array)
        for (int64_t c : std::get<std::vector<int64_t>>(f.value)) walk(c, stack);
    }
  }
};

} // namespace

std::optional<ShadowedParameter> findShadowedParameter(const Node &def,
                                                       BlockLoopLookup lookup) {
  ShadowWalk w{lookup, {{}}, {0}, {}, {}};
  if (const Node *ps = lookup(ref(def, "parameters"))) {
    for (llvm::StringRef key : {"requireds", "optionals", "posts", "keywords"})
      for (int64_t id : array(*ps, key))
        if (const Node *p = lookup(id)) w.owned[0].insert(str(*p, "name"));
  }
  std::vector<size_t> stack{0};
  w.walk(ref(def, "body"), stack);
  // A block's name (a parameter or a local of its own) shadows when a scope
  // enclosing the block owns the same name.
  // Every name a scope owns counts, wherever in the method it is written:
  // the analysis gives the method one slot per name, so a later use would
  // share it just as an earlier one would.
  for (const ShadowWalk::Param &p : w.params) {
    for (size_t s = w.parent[p.scope];; s = w.parent[s]) {
      if (w.owned[s].count(p.name)) return ShadowedParameter{p.node, p.name};
      if (s == 0) break;
    }
  }
  return std::nullopt;
}

std::string blockSlotName(llvm::StringRef written, const BlockLoop &loop,
                          BlockLoopLookup lookup,
                          llvm::function_ref<std::string(int64_t)> analysedName,
                          llvm::function_ref<bool(llvm::StringRef)> hasSlot) {
  int64_t declaring = -1;
  for (size_t i = 0; i < loop.params.size() && i < loop.paramNodes.size(); ++i)
    if (loop.params[i] == written) {
      declaring = loop.paramNodes[i];
      break;
    }
  if (declaring < 0) {
    // The block's first write of its own local, in source order.
    std::vector<int64_t> work{loop.body};
    std::set<int64_t> seen;
    while (declaring < 0 && !work.empty()) {
      const int64_t id = work.back();
      work.pop_back();
      if (id < 0 || !seen.insert(id).second) continue;
      const Node *n = lookup(id);
      if (!n) continue;
      if (n->kind == "LocalVariableWriteNode" && str(*n, "name") == written) {
        declaring = id;
        break;
      }
      std::vector<int64_t> kids;
      for (const AstField &f : n->fields) {
        if (f.kind == AstField::Kind::Reference)
          kids.push_back(std::get<int64_t>(f.value));
        else if (f.kind == AstField::Kind::Array)
          for (int64_t c : std::get<std::vector<int64_t>>(f.value)) kids.push_back(c);
      }
      work.insert(work.end(), kids.rbegin(), kids.rend());
    }
  }
  if (declaring >= 0) {
    const std::string slot = analysedName(declaring);
    if (slot != written && llvm::StringRef(slot).starts_with(written.str() + "__b") &&
        hasSlot(slot))
      return slot;
  }
  return written.str();
}

std::vector<BlockLoop> blockLoopsUnder(const Node &def, BlockLoopLookup lookup) {
  std::vector<BlockLoop> out;
  std::set<int64_t> seen;
  std::vector<int64_t> work{ref(def, "body")};
  // Depth first in source order: children are pushed in reverse.
  while (!work.empty()) {
    const int64_t id = work.back();
    work.pop_back();
    if (id < 0 || !seen.insert(id).second) continue;
    const Node *n = lookup(id);
    if (!n) continue;
    if (n->kind == "CallNode") {
      BlockLoopShape shape = classifyBlockLoop(*n, lookup);
      if (shape.loop) out.push_back(*shape.loop);
    }
    std::vector<int64_t> kids;
    for (const AstField &f : n->fields) {
      if (f.kind == AstField::Kind::Reference) kids.push_back(std::get<int64_t>(f.value));
      else if (f.kind == AstField::Kind::Array)
        for (int64_t c : std::get<std::vector<int64_t>>(f.value)) kids.push_back(c);
    }
    for (auto it = kids.rbegin(); it != kids.rend(); ++it) work.push_back(*it);
  }
  // Node ids follow the source, so this is source order.
  std::sort(out.begin(), out.end(),
            [](const BlockLoop &a, const BlockLoop &b) { return a.call < b.call; });
  return out;
}

} // namespace spinel_mlir::core
