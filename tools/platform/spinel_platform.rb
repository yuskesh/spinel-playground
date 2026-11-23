# tools/platform/spinel_platform.rb -- shared reader of the platform ledger,
# the T-5 profile formats and the T-2 tier declaration.  [E090, P008 Phase 1 /
# E168: Ruby]
#
# **A copy of the frozen `spinel_platform.py`.** Neither the messages nor the order of checks change —
# E168's only claim is "for the same argv, stdout / stderr / rc are byte-equal",
# and the moment it is rounded to "the same meaning" it is no longer a claim.
#
# One face is not moved: `expand_freestanding` (the freestanding lane became native,
# so the Ruby side does not need this path). It stays on the Python side.
#
# Consumer: tools/platform/spinel-capcheck (Ruby). The frozen Python module is still read by
# `tools/mlir/spinel-mlirgen.py` / `tools/freestanding/{undef-check,extern-check}.py`
# as before (so the module file was not moved).
require "yaml"
require "open3"

module SpinelPlatform
  HERE = File.dirname(File.expand_path(__FILE__))
  REPO = File.dirname(File.dirname(HERE))
  MENUS_PATH = File.join(HERE, "menus.yaml")
  ARENA_PATH = File.join(HERE, "arena.yaml")

  TIERS = ["core", "arena", "full"].freeze
  SUPPLIES = ["full", "externs-only", "trap-only"].freeze
  RESERVED_PREFIXES = ["edge/", "cloudflare/", "fastly/"].freeze
  RESERVED_CONSTANTS = ["Edge", "Cloudflare", "Fastly"].freeze

  KINDS = ["tier-violation", "menu-violation", "tier-core-lane", "tier-unknown",
           "reserved-name", "arena-gc-semantics", "arena-escape",
           "profile-error"].freeze

  # A copy of `SystemExit("msg")`. The frozen Python fails a lie in the ledger's structure as a **plain error**
  # with rc 1 (not a REJECT line), so the spelling and rc are the same here.
  class LedgerDeath < StandardError; end

  class LedgerError < StandardError
    attr_reader :kind, :detail
    def initialize(kind, detail)
      super(detail)
      @kind = kind
      @detail = detail
    end
  end

  # The same spelling as Python's `repr()` (ASCII string). The ledger's die messages use `%r`.
  def self.py_repr(s)
    "'" + s.to_s.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'") + "'"
  end

  # The repr of Python's `list(...)`. `['core', 'arena', 'full']`.
  def self.py_list(a)
    "[" + a.map { |x| py_repr(x) }.join(", ") + "]"
  end

  def self.reject_line(prog, kind, detail)
    raise "unknown kind #{kind}" unless KINDS.include?(kind)
    "#{prog}: REJECT #{kind}: #{detail}"
  end

  def self.tier_rank(t) = TIERS.index(t)

  def self.load_yaml(path)
    YAML.safe_load(File.read(path), permitted_classes: [], aliases: true)
  end

  # A copy of `os.path.relpath(path, start)` (start defaults to cwd).
  def self.relpath(path, start = Dir.pwd)
    p = File.expand_path(path).split("/")
    s = File.expand_path(start).split("/")
    i = 0
    i += 1 while i < p.size && i < s.size && p[i] == s[i]
    ([".."] * (s.size - i) + p[i..]).join("/").then { |r| r.empty? ? "." : r }
  end

  def self.load_menus(path = nil)
    path ||= MENUS_PATH
    d = load_yaml(path)
    if !d.is_a?(Hash) || !d.key?("platforms") || !d.key?("capabilities")
      raise LedgerDeath, "#{path}: the ledger needs `capabilities:` and `platforms:`"
    end
    if (d["tiers"] || []) != TIERS
      raise LedgerDeath, "#{path}: `tiers:` must be #{py_list(TIERS)} (T-1)"
    end
    d["capabilities"].each do |name, spec|
      unless RESERVED_PREFIXES.any? { |p| name.start_with?(p) }
        raise LedgerDeath, "#{path}: capability #{py_repr(name)} is outside the " \
                           "reserved namespaces #{py_list(RESERVED_PREFIXES)}"
      end
      unless spec.is_a?(Hash) && TIERS.include?(spec["tier"])
        raise LedgerDeath, "#{path}: capability #{py_repr(name)} needs `tier:` " \
                           "in #{py_list(TIERS)}"
      end
    end
    d["platforms"].each do |pname, p|
      unless p.is_a?(Hash) && p.key?("menu") && p.key?("arch")
        raise LedgerDeath, "#{path}: platform #{py_repr(pname)} needs `arch:` and `menu:`"
      end
      p["menu"].each do |c|
        unless d["capabilities"].key?(c)
          raise LedgerDeath, "#{path}: platform #{py_repr(pname)} menus " \
                             "#{py_repr(c)}, which `capabilities:` does not define"
        end
      end
    end
    d["_path"] = path
    d
  end

  def self.supplied_by(menus, cap)
    menus["platforms"].select { |_p, spec| spec["menu"].include?(cap) }.keys.sort
  end

  # ---- T-2: tier declaration (magic comment) ------------------------------
  TIER_RE = /\A#\s*spinel-tier:\s*(\S+)\s*\z/

  def self.read_spinel_tier(path)
    head = File.binread(path, 4096).to_s
    lines = head.force_encoding("UTF-8").scrub("�").split("\n", -1)[0, 2] || []
    lines.each_with_index do |line, i|
      break unless line.start_with?("#")
      next if line.start_with?("#!")
      m = TIER_RE.match(line)
      return [m[1], i + 1] if m
    end
    [nil, 0]
  end

  def self.resolve_tier(path, declared = nil)
    if declared.nil?
      declared, line = read_spinel_tier(path)
    else
      line = 0
    end
    return ["full", false] if declared.nil?
    unless TIERS.include?(declared)
      raise LedgerError.new(
        "tier-unknown",
        "'#{declared}' is not a spinel tier (#{TIERS.join('|')}) -- entry " \
        "#{File.basename(path)}#{line != 0 ? " line #{line}" : ''} declares it")
    end
    [declared, true]
  end

  # ---- T-5: profile -------------------------------------------------------
  DEPRECATION_NOTE = "note: profile %s uses the pre-T5 format (deprecated; " \
                     "P008 Phase 2 canonicalizes the platform-first form); " \
                     "accepted unchanged"

  def self.load_profile(path, menus = nil, prog: "spinel-platform", note: true)
    data = load_yaml(path)
    unless data.is_a?(Hash)
      raise LedgerError.new("profile-error",
        "#{path} is not a YAML mapping (a profile is either the T-5 " \
        "platform-first form or the pre-T5 target/abi/runtime/platform form)")
    end
    unless data["platform"].is_a?(String)
      $stderr.write("#{prog}: #{format(DEPRECATION_NOTE, path)}\n") if note
      return { "format" => "old", "path" => path, "data" => data }
    end
    menus ||= load_menus
    unknown = data.keys - ["platform", "arch", "supplies", "externs"]
    unless unknown.empty?
      raise LedgerError.new("profile-error",
        "#{path}: unknown key(s) #{unknown.sort.join(', ')} (a T-5 profile has " \
        "platform/arch/supplies/externs)")
    end
    plat = data["platform"]
    unless menus["platforms"].key?(plat)
      raise LedgerError.new("profile-error",
        "#{path}: unknown platform '#{plat}' -- the ledger " \
        "(#{relpath(menus['_path'], REPO)}) knows #{menus['platforms'].keys.sort.join(', ')}")
    end
    arch_menu = menus["platforms"][plat]["arch"] || {}
    arch = data["arch"]
    if arch.nil?
      if arch_menu.size == 1
        arch = arch_menu.keys.first
      else
        raise LedgerError.new("profile-error",
          "#{path}: platform '#{plat}' has #{arch_menu.size} arch entries " \
          "(#{arch_menu.keys.sort.join(', ')}); `arch:` cannot be derived and " \
          "must be chosen".sub("()", "(-)"))
      end
    elsif !arch_menu.key?(arch)
      raise LedgerError.new("profile-error",
        "#{path}: arch '#{arch}' is not in platform '#{plat}' menu " \
        "(#{arch_menu.keys.sort.join(', ').then { |s| s.empty? ? '-' : s }})")
    end
    supplies = data["supplies"]
    unless SUPPLIES.include?(supplies)
      raise LedgerError.new("profile-error",
        "#{path}: supplies '#{supplies.nil? ? 'None' : supplies}' is not one of " \
        "#{SUPPLIES.join('|')}")
    end
    externs = data["externs"]
    if supplies != "externs-only" && externs && !(externs.respond_to?(:empty?) && externs.empty?)
      n = externs.size
      raise LedgerError.new("profile-error",
        "#{path}: `externs:` only means something with supplies: externs-only " \
        "(D-7); supplies: #{supplies} got #{n} entr#{n == 1 ? 'y' : 'ies'}")
    end
    { "format" => "new", "path" => path, "platform" => plat, "arch" => arch,
      "supplies" => supplies, "externs" => (externs || []).to_a }
  end

  # ---- T-2 + T-3 ----------------------------------------------------------
  def self.check_capabilities(menus, platform, tier, required)
    errs = []
    menu = menus["platforms"][platform]["menu"]
    required.sort.each do |cap|
      need = menus["capabilities"][cap]["tier"]
      if tier_rank(tier) < tier_rank(need)
        errs << LedgerError.new("tier-violation",
          "capability '#{cap}' requires tier #{need}+ (ledger), but the entry " \
          "declares tier #{tier} (# spinel-tier)")
      end
      next if menu.include?(cap)
      sup = supplied_by(menus, cap)
      errs << LedgerError.new("menu-violation",
        "capability '#{cap}' is not in platform '#{platform}' menu (supplied by: " \
        "#{sup.empty? ? 'no platform yet' : sup.join(', ')})")
    end
    errs
  end

  # ---- the typedump `ast` face that T-4 / T-1 read -------------------------
  def self.parse_ast(text)
    files, types, sname, ifield, parent = {}, {}, {}, {}, {}
    text.split("\n", -1).each do |line|
      next if line.empty?
      f = line.split(" ", 4)
      case f[0]
      when "FILE"
        files[f[1].to_i] = f[2] if f.size >= 3
      when "N"
        types[f[1].to_i] = f[2] if f.size >= 3
      when "S"
        (sname[f[1].to_i] ||= {})[f[2]] = f[3] if f.size >= 4
      when "I"
        (ifield[f[1].to_i] ||= {})[f[2]] = f[3].to_i if f.size >= 4
      when "R"
        parent[f[3].to_i] = f[1].to_i if f.size >= 4
      when "A"
        if f.size >= 4
          f[3].split(",").each { |c| parent[c.to_i] = f[1].to_i unless c.empty? }
        end
      end
    end
    [files, types, sname, ifield, parent]
  end

  def self.reserved_name_errors(ast_text, reserved = RESERVED_CONSTANTS)
    files, types, sname, ifield, parent = parse_ast(ast_text)
    errs = []
    types.sort_by { |nid, _| nid }.each do |nid, kind|
      name = nil
      if kind == "ModuleNode" || kind == "ClassNode"
        parent.each do |cid, pid|
          if pid == nid && types[cid] == "ConstantReadNode"
            name = (sname[cid] || {})["name"]
            break
          end
        end
      elsif kind == "ConstantWriteNode"
        name = (sname[nid] || {})["name"]
      else
        next
      end
      next unless reserved.include?(name)
      p = parent[nid]
      nested = false
      while !p.nil?
        if ["ModuleNode", "ClassNode"].include?(types[p])
          nested = true
          break
        end
        p = parent[p]
      end
      next if nested
      path = files[((ifield[nid] || {})["node_file"] || -1)] || "?"
      line = (ifield[nid] || {})["node_line"] || 0
      dirpath = File.dirname(File.expand_path(path))
      owner = File.basename(dirpath)
      next if owner == name.downcase
      stem = File.basename(path, File.extname(path))
      if owner == stem
        grandparent = File.basename(File.dirname(dirpath))
        next if grandparent == name.downcase
      end
      errs << LedgerError.new("reserved-name",
        "#{File.exist?(path) ? relpath(path) : path}:#{line} defines top-level " \
        "'#{name}', which is a Spinel-reserved namespace (R016 T-4: " \
        "#{RESERVED_CONSTANTS.join('/')}).  A capability file may define it -- " \
        "one whose directory IS the family, e.g. <root>/#{name.downcase}/" \
        "<capability>.rb, or the colocated form <root>/#{name.downcase}/" \
        "<capability>/<capability>.rb -- but a program file may not, because " \
        "the same spelling would then mean two things.  Rename the constant")
    end
    errs
  end

  # ---- T-1: arenacheck ----------------------------------------------------
  def self.load_arena_rules(path = nil)
    path ||= ARENA_PATH
    d = load_yaml(path)
    if !d.is_a?(Hash) || !d.key?("gc_semantics") || !d.key?("escape")
      raise LedgerDeath, "#{path}: the arena ledger needs `gc_semantics:` and `escape:`"
    end
    consts = (d["gc_semantics"] || {})["constants"] || {}
    if !consts.is_a?(Hash) || consts.empty?
      raise LedgerDeath, "#{path}: gc_semantics.constants must be a non-empty " \
                         "mapping name -> {why: ...}"
    end
    esc = d["escape"] || {}
    ["scopes", "unboxed_types", "exempt_globals"].each do |key|
      raise LedgerDeath, "#{path}: escape.#{key} is missing" unless esc.key?(key)
    end
    (esc["scopes"] || {}).each do |sname, spec|
      unless ["reject", "allow"].include?((spec || {})["action"])
        raise LedgerDeath, "#{path}: escape.scopes.#{sname} needs action: reject|allow"
      end
    end
    d["_path"] = path
    d
  end

  # Undo spinel-typedump's ast_esc (%XX).
  def self.ast_unesc(s)
    out = +""
    i = 0
    while i < s.length
      if s[i] == "%" && i + 2 < s.length
        hex = s[i + 1, 2]
        if hex =~ /\A[0-9A-Fa-f]{2}\z/
          out << hex.to_i(16).chr
          i += 3
          next
        end
      end
      out << s[i]
      i += 1
    end
    out
  end

  def self.site(files, ifield, nid)
    path = ast_unesc(files[((ifield[nid] || {})["node_file"] || -1)] || "?")
    line = (ifield[nid] || {})["node_line"] || 0
    rel = File.exist?(path) ? relpath(path) : path
    "#{rel}:#{line}"
  end

  def self.arena_gc_errors(ast_text, rules)
    files, types, sname, ifield, _parent = parse_ast(ast_text)
    banned = (rules["gc_semantics"] || {})["constants"] || {}
    errs = []
    types.sort_by { |nid, _| nid }.each do |nid, kind|
      next unless kind == "ConstantReadNode"
      name = (sname[nid] || {})["name"]
      next unless banned.key?(name)
      note = (((banned[name] || {})["note"] || "-")).split(/\s+/).reject(&:empty?).join(" ")
      errs << LedgerError.new("arena-gc-semantics",
        "#{site(files, ifield, nid)} mentions '#{name}', a GC-semantics name -- " \
        "tier arena never runs collect() (lib/sp_gc.c returns immediately under " \
        "SP_REQUEST_ARENA), so this is a SILENT change of meaning, not an error.  " \
        "#{note} [#{relpath(rules['_path'], REPO)}].  Remove it, or declare " \
        "`# spinel-tier: full`")
    end
    errs
  end

  GVAR_WRITE_NODES = ["GlobalVariableWriteNode", "GlobalVariableOperatorWriteNode",
                      "GlobalVariableOrWriteNode", "GlobalVariableAndWriteNode",
                      "GlobalVariableTargetNode"].freeze

  def self.parse_globals_table(tsv_text)
    out = {}
    tsv_text.split("\n", -1).drop(1).each do |line|
      name, _sep, ty = line.partition("\t")
      out[name] = ty.strip unless name.empty?
    end
    out
  end

  def self.arena_escape_errors(ast_text, globals_text, rules)
    esc = rules["escape"]
    return [] if (((esc["scopes"] || {})["global"]) || {})["action"] != "reject"
    unboxed = (esc["unboxed_types"] || []).to_a
    exempt = (esc["exempt_globals"] || []).to_a
    gtypes = parse_globals_table(globals_text)
    files, types, sname, ifield, _parent = parse_ast(ast_text)

    seen, errs = {}, []
    types.sort_by { |nid, _| nid }.each do |nid, kind|
      next unless GVAR_WRITE_NODES.include?(kind)
      name = (sname[nid] || {})["name"]
      next if name.nil? || name.empty? || exempt.include?(name)
      ty = gtypes.fetch(name, "unknown")
      next if unboxed.include?(ty)
      key = [name, ty]
      next if seen.key?(key)
      seen[key] = true
      errs << LedgerError.new("arena-escape",
        "#{site(files, ifield, nid)} stores into global '#{name}', whose " \
        "whole-program type is '#{ty}' -- not one of the unboxed types the " \
        "ledger (#{relpath(rules['_path'], REPO)}) allows across a request " \
        "(#{unboxed.sort.join('|')}).  A global outlives the request, and tier " \
        "arena frees ALL request memory at the end of the request (R016 T-1), so " \
        "the reference would dangle the moment an instance is reused.  Keep the " \
        "value in a local, store an unboxed scalar, or declare " \
        "`# spinel-tier: full`")
    end
    errs
  end
end
