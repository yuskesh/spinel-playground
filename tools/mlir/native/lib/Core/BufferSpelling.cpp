#include "spinel-mlir/Core/BufferSpelling.h"

#include "llvm/ADT/StringExtras.h"

#include <algorithm>

extern "C" {
#include "prism.h"
}

namespace spinel_mlir::core {
namespace {

using contract::BufferSpelling;

/// The walk over the vendored Prism's tree (vendor/spinel's libprism.a, which
/// the contract reader links too): strings, heredocs, comments and `=begin`
/// are Prism's, never this file's.
struct Walk {
  pm_parser_t *parser = nullptr;
  const uint8_t *base = nullptr;
  std::vector<size_t> lineStarts;  ///< byte offset of each line's start
  std::vector<BufferSpelling> spelled;
  /// A call to rewrite, by its offsets in the source.
  struct Call {
    size_t start, open;   ///< the call's first byte; its `(`
    size_t lastArgEnd;    ///< after the last argument (open + 1 when none)
    size_t args;          ///< the number of arguments
    bool floatElement;
    bool integerFill;     ///< a Buffer's second argument is an Integer literal
    size_t fillEnd;
  };
  std::vector<Call> calls;
  std::vector<std::string> modules;  ///< the module and class names the walk is in

  size_t offset(const uint8_t *p) const { return static_cast<size_t>(p - base); }
  std::pair<int64_t, int64_t> lineCol(size_t at) const {
    auto it = std::upper_bound(lineStarts.begin(), lineStarts.end(), at);
    const size_t line = static_cast<size_t>(it - lineStarts.begin());  // 1-based
    return {static_cast<int64_t>(line), static_cast<int64_t>(at - lineStarts[line - 1])};
  }
  llvm::StringRef constant(pm_constant_id_t id) const {
    if (id == 0) return {};
    const pm_constant_t *c = pm_constant_pool_id_to_constant(&parser->constant_pool, id);
    return c ? llvm::StringRef(reinterpret_cast<const char *>(c->start), c->length) : llvm::StringRef();
  }
  llvm::StringRef text(const pm_location_t &l) const {
    if (!l.start || !l.end) return {};
    return llvm::StringRef(reinterpret_cast<const char *>(l.start), l.end - l.start);
  }
  bool readsCore(const pm_node_t *n) const {
    if (!n) return false;
    if (PM_NODE_TYPE(n) == PM_CONSTANT_READ_NODE)
      return constant(reinterpret_cast<const pm_constant_read_node_t *>(n)->name) == "Core";
    if (PM_NODE_TYPE(n) == PM_CONSTANT_PATH_NODE) {  // ::Core
      const auto *p = reinterpret_cast<const pm_constant_path_node_t *>(n);
      return !p->parent && constant(p->name) == "Core";
    }
    return false;
  }
  /// "Buffer" or "Table" when `n` is `Core::Buffer`/`Core::Table` (or
  /// `::Core::...`); empty otherwise. `Doom::Core::Buffer` is not.
  llvm::StringRef bufferClass(const pm_node_t *n) const {
    if (!n || PM_NODE_TYPE(n) != PM_CONSTANT_PATH_NODE) return {};
    const auto *p = reinterpret_cast<const pm_constant_path_node_t *>(n);
    const llvm::StringRef name = constant(p->name);
    if (name != "Buffer" && name != "Table") return {};
    return readsCore(p->parent) ? name : llvm::StringRef();
  }
  /// The source's top-level `Core` when the walk is directly inside it.
  bool inCore() const { return modules.size() == 1 && modules[0] == "Core"; }
  void reserve(const pm_node_t *at, llvm::StringRef cls, const char *what) {
    reserveName(at, ("Core::" + cls).str(), what);
  }
  void reserveName(const pm_node_t *at, std::string name, const char *what) {
    auto [line, col] = lineCol(offset(at->location.start));
    spelled.push_back({BufferSpelling::Kind::Reserved, line, col, std::move(name), what});
  }
  /// At the top level (or `::Core`), outside every module and class.
  bool topLevel() const { return modules.empty(); }
  /// The name a module or class statement opens: `Core` (also `::Core`),
  /// "Core::Buffer" for that path, "<path>" for another path.
  std::string opened(const pm_node_t *path) const {
    if (!path) return {};
    if (readsCore(path)) return "Core";
    if (PM_NODE_TYPE(path) == PM_CONSTANT_READ_NODE)
      return constant(reinterpret_cast<const pm_constant_read_node_t *>(path)->name).str();
    if (llvm::StringRef c = bufferClass(path); !c.empty()) return ("Core::" + c).str();
    return "<path>";
  }

  void call(const pm_call_node_t *c) {
    const llvm::StringRef method = constant(c->name);
    const pm_node_t *recv = c->receiver;
    std::vector<const pm_node_t *> args;
    if (c->arguments)
      for (size_t i = 0; i < c->arguments->arguments.size; ++i)
        args.push_back(c->arguments->arguments.nodes[i]);
    std::string argText;
    if (!args.empty())
      argText = llvm::StringRef(reinterpret_cast<const char *>(args.front()->location.start),
                                args.back()->location.end - args.front()->location.start)
                    .str();
    if (recv && PM_NODE_TYPE(recv) == PM_CONSTANT_READ_NODE && method == "new" &&
        constant(reinterpret_cast<const pm_constant_read_node_t *>(recv)->name) == "Array") {
      auto [line, col] = lineCol(offset(c->base.location.start));
      spelled.push_back({BufferSpelling::Kind::ArrayNew, line, col, "", argText});
      return;
    }
    const llvm::StringRef cls = bufferClass(recv);
    // Only `Core::Buffer.<name>(` with its parenthesis straight after the
    // name; another spelling is left for the checker to refuse.
    const bool open = c->opening_loc.start && c->closing_loc.start &&
                      text(c->opening_loc) == "(" && c->message_loc.end == c->opening_loc.start;
    if (cls.empty() || !open) return;
    auto [line, col] = lineCol(offset(c->base.location.start));
    spelled.push_back({cls == "Buffer" ? BufferSpelling::Kind::Buffer : BufferSpelling::Kind::Table,
                       line, col, method.str(), argText});
    Call k{};
    k.start = offset(c->base.location.start);
    k.open = offset(c->opening_loc.start);
    k.args = args.size();
    k.lastArgEnd = args.empty() ? k.open + 1 : offset(args.back()->location.end);
    k.floatElement = method == "f32" || method == "f64";
    k.integerFill = cls == "Buffer" && args.size() == 2 && PM_NODE_TYPE(args[1]) == PM_INTEGER_NODE;
    k.fillEnd = args.size() == 2 ? offset(args[1]->location.end) : 0;
    calls.push_back(k);
  }

  static bool visit(const pm_node_t *n, void *data) {
    Walk &w = *static_cast<Walk *>(data);
    switch (PM_NODE_TYPE(n)) {
    case PM_CALL_NODE:
      w.call(reinterpret_cast<const pm_call_node_t *>(n));
      return true;
    case PM_MODULE_NODE:
    case PM_CLASS_NODE: {
      const bool mod = PM_NODE_TYPE(n) == PM_MODULE_NODE;
      const pm_node_t *path = mod ? reinterpret_cast<const pm_module_node_t *>(n)->constant_path
                                  : reinterpret_cast<const pm_class_node_t *>(n)->constant_path;
      const char *what = mod ? "a module" : "a class";
      const std::string name = w.opened(path);
      if (!mod && name == "Core" && w.topLevel() &&
          reinterpret_cast<const pm_class_node_t *>(n)->superclass)
        w.reserveName(n, "Core", "a class with a superclass");
      if (llvm::StringRef(name).starts_with("Core::"))
        w.reserve(n, llvm::StringRef(name).drop_front(6), what);
      else if (w.inCore() && (name == "Buffer" || name == "Table"))
        w.reserve(n, name, what);
      w.modules.push_back(name);
      pm_visit_child_nodes(n, visit, data);
      w.modules.pop_back();
      return false;
    }
    case PM_SINGLETON_CLASS_NODE: {
      const auto *s = reinterpret_cast<const pm_singleton_class_node_t *>(n);
      if (llvm::StringRef c = w.bufferClass(s->expression); !c.empty())
        w.reserve(n, c, "a singleton class");
      w.modules.push_back("<singleton>");
      pm_visit_child_nodes(n, visit, data);
      w.modules.pop_back();
      return false;
    }
    case PM_CONSTANT_WRITE_NODE:
    case PM_CONSTANT_OR_WRITE_NODE:
    case PM_CONSTANT_AND_WRITE_NODE:
    case PM_CONSTANT_OPERATOR_WRITE_NODE:
    case PM_CONSTANT_TARGET_NODE: {
      pm_constant_id_t id = 0;
      switch (PM_NODE_TYPE(n)) {
      case PM_CONSTANT_WRITE_NODE: id = reinterpret_cast<const pm_constant_write_node_t *>(n)->name; break;
      case PM_CONSTANT_OR_WRITE_NODE: id = reinterpret_cast<const pm_constant_or_write_node_t *>(n)->name; break;
      case PM_CONSTANT_AND_WRITE_NODE: id = reinterpret_cast<const pm_constant_and_write_node_t *>(n)->name; break;
      case PM_CONSTANT_OPERATOR_WRITE_NODE: id = reinterpret_cast<const pm_constant_operator_write_node_t *>(n)->name; break;
      default: id = reinterpret_cast<const pm_constant_target_node_t *>(n)->name; break;
      }
      const llvm::StringRef name = w.constant(id);
      if (w.inCore() && (name == "Buffer" || name == "Table")) w.reserve(n, name, "a constant");
      if (w.topLevel() && name == "Core") w.reserveName(n, "Core", "a constant");
      return true;
    }
    case PM_CONSTANT_PATH_WRITE_NODE:
    case PM_CONSTANT_PATH_OR_WRITE_NODE:
    case PM_CONSTANT_PATH_AND_WRITE_NODE:
    case PM_CONSTANT_PATH_OPERATOR_WRITE_NODE: {
      const pm_constant_path_node_t *target = nullptr;
      switch (PM_NODE_TYPE(n)) {
      case PM_CONSTANT_PATH_WRITE_NODE: target = reinterpret_cast<const pm_constant_path_write_node_t *>(n)->target; break;
      case PM_CONSTANT_PATH_OR_WRITE_NODE: target = reinterpret_cast<const pm_constant_path_or_write_node_t *>(n)->target; break;
      case PM_CONSTANT_PATH_AND_WRITE_NODE: target = reinterpret_cast<const pm_constant_path_and_write_node_t *>(n)->target; break;
      default: target = reinterpret_cast<const pm_constant_path_operator_write_node_t *>(n)->target; break;
      }
      if (llvm::StringRef c = w.bufferClass(reinterpret_cast<const pm_node_t *>(target)); !c.empty())
        w.reserve(n, c, "a constant");
      if (w.readsCore(reinterpret_cast<const pm_node_t *>(target))) w.reserveName(n, "Core", "a constant");  // ::Core = ...
      return true;
    }
    case PM_CONSTANT_PATH_TARGET_NODE: {  // `Core::Buffer, x = ...`
      const auto *t = reinterpret_cast<const pm_constant_path_target_node_t *>(n);
      const llvm::StringRef name = w.constant(t->name);
      if (w.readsCore(t->parent) && (name == "Buffer" || name == "Table")) w.reserve(n, name, "a constant");
      if (!t->parent && name == "Core") w.reserveName(n, "Core", "a constant");  // ::Core, x = ...
      return true;
    }
    case PM_DEF_NODE: {
      const auto *d = reinterpret_cast<const pm_def_node_t *>(n);
      const llvm::StringRef name = w.constant(d->name);
      const pm_node_t *r = d->receiver;
      const bool onCore = w.readsCore(r) || (w.inCore() && (!r || PM_NODE_TYPE(r) == PM_SELF_NODE));
      if (onCore && (name == "Buffer" || name == "Table")) w.reserve(n, name, "a method");
      if (llvm::StringRef c = w.bufferClass(r); !c.empty()) w.reserve(n, c, "a method on it");
      return true;
    }
    default:
      return true;
    }
  }
};

} // namespace

std::string sourceColumns(llvm::StringRef text, llvm::StringRef copyPath,
                          llvm::ArrayRef<contract::ColumnInsert> inserts) {
  if (inserts.empty() || copyPath.empty()) return text.str();
  const std::string key = (copyPath + ":").str();
  std::string out;
  size_t at = 0;
  while (true) {
    const size_t hit = text.find(key, at);
    if (hit == llvm::StringRef::npos) break;
    size_t ld = hit + key.size(), le = ld;
    while (le < text.size() && llvm::isDigit(text[le])) ++le;
    size_t cd = le + 1, ce = cd;
    while (ce < text.size() && llvm::isDigit(text[ce])) ++ce;
    int64_t line = 0, col = 0;
    if (le > ld && le < text.size() && text[le] == ':' && ce > cd &&
        !text.slice(ld, le).getAsInteger(10, line) && !text.slice(cd, ce).getAsInteger(10, col)) {
      out += text.slice(at, cd).str();
      // A diagnostic's column counts from 1, the record's from 0.
      out += std::to_string(col > 0 ? contract::sourceColumn(inserts, line, col - 1) + 1 : col);
      at = ce;
    } else {
      out += text.slice(at, le).str();
      at = le;
    }
  }
  out += text.substr(at).str();
  return out;
}

bool isBufferElement(llvm::StringRef name) {
  static const char *const kNames[] = {"i8", "i16", "i32", "i64", "u8", "u16", "u32", "f32", "f64"};
  for (const char *n : kNames)
    if (name == n) return true;
  return false;
}

BufferRewrite rewriteBufferSpellings(llvm::StringRef source) {
  BufferRewrite out;
  out.text = source.str();
  // Most sources spell none of these, and are not parsed here.
  if (!source.contains("Core") && !source.contains("Array.new")) return out;

  pm_parser_t parser;
  const auto *bytes = reinterpret_cast<const uint8_t *>(source.data());
  pm_parser_init(&parser, bytes, source.size(), nullptr);
  pm_node_t *root = pm_parse(&parser);
  // A source Prism cannot parse is not rewritten: the reader gets it as
  // written and its own diagnostics name the source's lines and columns
  // (the review: a fill appended to a broken count made a new error).
  if (parser.error_list.size > 0) {
    pm_node_destroy(&parser, root);
    pm_parser_free(&parser);
    return out;
  }
  Walk w;
  w.parser = &parser;
  w.base = bytes;
  w.lineStarts.push_back(0);
  for (size_t i = 0; i < source.size(); ++i)
    if (source[i] == '\n') w.lineStarts.push_back(i + 1);
  pm_visit_node(root, Walk::visit, &w);
  pm_node_destroy(&parser, root);
  pm_parser_free(&parser);
  out.spelled = std::move(w.spelled);
  if (w.calls.empty()) return out;

  // Edits are (offset, length removed, text inserted).
  struct Edit { size_t at, remove; std::string insert; };
  std::vector<Edit> edits;
  for (const Walk::Call &k : w.calls) {
    const size_t width = k.open + 1 - k.start;  // through the `(`, at least 15
    edits.push_back({k.start, width, "Array.new(" + std::string(width - 10, ' ')});
    if (k.args == 1)
      edits.push_back({k.lastArgEnd, 0, k.floatElement ? ", 0.0" : ", 0"});
    else if (k.args == 2 && k.floatElement && k.integerFill)
      edits.push_back({k.fillEnd, 0, ".0"});
  }
  // A call nested in another's arguments comes later in the walk: apply the
  // edits by offset.
  std::stable_sort(edits.begin(), edits.end(), [](const Edit &a, const Edit &b) { return a.at < b.at; });
  for (const Edit &e : edits)
    if (e.remove == 0) {
      auto [line, col] = w.lineCol(e.at);
      out.inserts.push_back({line, col, static_cast<int64_t>(e.insert.size())});
    }
  out.text.clear();
  size_t from = 0;
  for (const Edit &e : edits) {
    out.text.append(source.data() + from, e.at - from);
    out.text += e.insert;
    from = e.at + e.remove;
  }
  out.text.append(source.data() + from, source.size() - from);
  out.changed = true;
  return out;
}

} // namespace spinel_mlir::core
