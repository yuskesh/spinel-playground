# frozen_string_literal: true
#
# tools/doom/core-entries.rb — decision 0008's three entries, generated.
#
#   ruby tools/doom/core-entries.rb [--core DIR] [--out DIR]
#
# --core reads the manifests and the port from DIR instead of
# examples/doom/core; --out writes src/doomentry.rb and entries/ under DIR
# (default: the core directory itself) -- how a check regenerates the committed
# files beside them, or from an altered manifest.
#
# 0008 fixes the names doom_core_input, doom_core_step and doom_core_render and
# says their parameter lists are generated from the reviewed state and access
# manifests. This writes, from the bodies below and the port's own signatures:
#
#   examples/doom/core/src/doomentry.rb      the three definitions
#   examples/doom/core/entries/NAME.contract each entry's kernel contract
#   examples/doom/core/entries/fields.tsv    which resident field each
#                                            parameter is
#
# A BODY IS THE LOOP'S ORDER, NOT A TIDIER ONE. Each is bin/doom.rb's code for
# its part of a tic, with the port's definitions in place of the original's
# methods. A call is written `CALL name(key: value, ...)`: every parameter of
# the callee not given is passed as the entry's buffer of the same name, which
# is the port's convention (tools/doom/buffer-names.rb) -- and a parameter that
# is not a buffer must be given, or the generator refuses. `key: @name` passes
# the entry's buffer `name` for that parameter instead.
#
# A PARAMETER'S FIELD comes from the entry's FIELDS below, or else from the
# first prefix that makes a field of examples/doom/core/state.tsv; `state` is
# core_state and the index table is `derived:` its slot table. Its element is
# the field's, and its mode is the entry's access.tsv row -- so a buffer the
# port writes and the manifest says the entry only reads is refused by the
# kernel, not granted. tests/doom-core/entry-fields.rb checks the result
# against the generated layout.
#
# A RESULT AND THE NON-COUNT SCALARS HAVE THE ENTRY'S WIDTH (decision 0022,
# the owner's decision of 2026-10-21). An entry whose `#width` line in
# entries/units.tsv is `target` computes at the target's 32 bits, and a 32-bit
# body takes no i64 scalar (0019), so its result and its scalars are `i32`;
# an entry still at `int64` keeps `i64`. The buffers' u64 counts are
# descriptor counts (0007) and do not change.
require "optparse"
require "fileutils"
ROOT = File.expand_path("../..", __dir__)
opt = {}
OptionParser.new do |o|
  o.on("--core DIR") { |v| opt[:core] = v }
  o.on("--out DIR") { |v| opt[:out] = v }
end.parse!
CORE = opt[:core] || File.join(ROOT, "examples/doom/core")
OUT = opt[:out] || CORE
OUT_SRC = File.join(OUT, "src/doomentry.rb")
OUT_DIR = File.join(OUT, "entries")
# each entry's Integer width, from the manifest's `#width` lines
WIDTHS = File.readlines(File.join(CORE, "entries/units.tsv"), chomp: true)
             .select { |l| l.start_with?("#width\t") }.to_h { |l| _, e, w = l.split("\t"); [e, w] }
FileUtils.mkdir_p([File.dirname(OUT_SRC), OUT_DIR])

# --- the port's signatures ------------------------------------------------------
raw = {}
Dir[File.join(CORE, "src/*.rb")].sort.each do |path|
  next if File.basename(path) == "doomentry.rb"
  File.read(path).scan(/^def (dc_\w+)\(([^)]*)\)\n(.*?)^end\n/m) do |name, params, body|
    raw[name] = [params.split(",").map(&:strip), body]
  end
end
def calls_in(body)
  out = []
  body.scan(/\b(dc_\w+)\(/) do
    name = Regexp.last_match(1)
    i = Regexp.last_match.end(0)
    depth = 0
    args = []
    cur = +""
    while i < body.size
      ch = body[i]
      if ch == "(" then depth += 1
      elsif ch == ")"
        break if depth.zero?
        depth -= 1
      elsif ch == "," && depth.zero?
        args << cur.strip
        cur = +""
        i += 1
        next
      end
      cur << ch
      i += 1
    end
    args << cur.strip
    out << [name, args]
  end
  out
end
# A parameter is a buffer when the body indexes it, or hands it on in a position
# that is a buffer in the callee: a fixed point over every definition.
INDEX_TABLES = %w[state gx rx xi zero_slots].freeze
buf = raw.to_h { |n, (ps, body)| [n, ps.to_h { |x| [x, INDEX_TABLES.include?(x) || body.match?(/\b#{Regexp.escape(x)}\[/)] }] }
loop do
  changed = false
  raw.each do |n, (ps, body)|
    calls_in(body).each do |callee, args|
      next unless raw.key?(callee)
      args.each_with_index do |a, i|
        cp = raw[callee][0][i]
        next unless cp && buf[callee][cp] && ps.include?(a) && !buf[n][a]
        buf[n][a] = true
        changed = true
      end
    end
  end
  break unless changed
end

# --- the manifests --------------------------------------------------------------
SCHEMA = {}
File.foreach(File.join(CORE, "state.tsv")) do |l|
  next if l.start_with?("#")
  f = l.chomp.split("\t")
  SCHEMA[f[0]] = { role: f[1], element: f[2], count: f[3] }
end
ACCESS = {}
File.foreach(File.join(CORE, "access.tsv")) do |l|
  next if l.start_with?("#") || l.strip.empty?
  e, f, m = l.chomp.split("\t")
  ACCESS[[e, f]] = m
end

# --- the entries ----------------------------------------------------------------
ENTRIES = [
  {
    name: "doom_core_input", index: "xi", slots: "input-slots.tsv",
    prefixes: [],
    fields: { "down" => "key_state_down", "script_code" => "key_script_code", "script_from" => "key_script_from",
              "script_to" => "key_script_to", "demo_buf" => "demo_writer_buf", "demo_max" => "demo_writer_max",
              "cmd" => "core_command" },
    buffers: %w[cmd],
    scalars: %w[scripted tic recording],
    comment: <<~TXT,
      # `doom_core_input`: bin/doom.rb's input step for a tic that is not played
      # from a demo. With `scripted` the key script's keys for `tic` replace the key
      # state; otherwise Full has stored the polled keys into `down`. The command is
      # built from the keys; with `recording` its angle is quantized and the tic's
      # four bytes are appended to the demo buffer -- which is all
      # DemoWriter#write_tic does: 0008's "Full writes recording bytes after a
      # successful input call" is DemoWriter#save, which stays Full's and writes
      # the buffer this fills. The command is published into `cmd` as 0008's five
      # cells; the fifth is the angle byte the demo carries, computed the same way
      # when not recording.
    TXT
    body: <<~RUBY,
      if n_cmd < 5
        core_fail(:capacity)
      end
      if scripted != 0
        CALL dc_in_apply(ncode: n_script_code, t: tic)
      end
      CALL dc_in_build()
      b = ((state[xi[X_ANGLETURN]] + 128) >> 8) & 0xff
      if recording != 0
        b = CALL dc_in_quantize_angle()
        CALL dc_in_write_tic(forwardmove: state[xi[X_FORWARDMOVE]], sidemove: state[xi[X_SIDEMOVE]], aturn_byte: b, buttons: state[xi[X_BUTTONS]])
      end
      cmd[0] = state[xi[X_FORWARDMOVE]]
      cmd[1] = state[xi[X_SIDEMOVE]]
      cmd[2] = state[xi[X_ANGLETURN]]
      cmd[3] = state[xi[X_BUTTONS]]
      cmd[4] = b
      0
    RUBY
  },
  {
    name: "doom_core_step", index: "gx", slots: "step-slots.tsv",
    prefixes: %w[game level textures random],
    fields: { "keyboxes" => "status_bar_keyboxes", "oldweaponsowned" => "status_bar_oldweaponsowned",
              "cmd" => "core_command", "ks" => "core_knot_stack", "sight_stack" => "core_sight_stack",
              "sound_stack" => "core_sound_stack", "kn_caps" => "core_step_caps" },
    buffers: %w[cmd],
    scalars: %w[predraws],
    comment: <<~TXT,
      # `doom_core_step`: bin/doom.rb's tic from `rnd.tic = t` to `hud.ticker`.
      # `predraws` M_Random draws come first -- the melt wipe's 320 at tic 2, which
      # Full cannot draw on CORE's generator itself; then the tick with the command
      # in `cmd`, the status bar's draw, the status bar's ticker with the attacker
      # and angle the loop computes, and the HUD's ticker with the tick's message.
      # `Random#tic=` writes only eliminated storage. The capacities are written
      # from the counts this entry was handed. Answers the completed gametic.
    TXT
    body: <<~RUBY,
      if n_cmd < 5
        core_fail(:capacity)
      end
      kn_caps[KN_CAP_SIGHT] = n_sight_stack
      kn_caps[KN_CAP_SOUND] = n_sound_stack
      kn_caps[KN_CAP_SWITCH] = n_switchlist
      d = 0
      while d < predraws
        dc_st_m_random(state, gx)
        d += 1
      end
      CALL dc_st_g_ticker(ks_n: n_ks, fwd: cmd[0], side: cmd[1], aturn: cmd[2], buttons: cmd[3])
      rn = dc_st_m_random(state, gx)
      m = player_mo[0]
      atk = state[gx[G_PL_ATTACKER]]
      kind = 0
      bga = 0
      if atk >= 0
        kind = atk == m ? 1 : 2
        bga = CALL dc_st_point_to_angle2(x1: mobj_x[m], y1: mobj_y[m], x2: mobj_x[atk], y2: mobj_y[atk])
      end
      CALL dc_st_sb_ticker(cards: @pl_cards, weaponowned: @pl_weaponowned, randomnumber: rn, health: state[gx[G_PL_HEALTH]], damagecount: state[gx[G_PL_DAMAGECOUNT]], bonuscount: state[gx[G_PL_BONUSCOUNT]], attackdown: state[gx[G_PL_ATTACKDOWN]], invulnerability: pl_powers[0], attacker: kind, badguyangle: bga, playerangle: mobj_angle[m])
      msg = dc_st_take_message(state, gx)
      dc_st_hud_ticker(state, gx, msg)
      state[gx[G_GAMETIC]]
    RUBY
  },
  {
    name: "doom_core_render", index: "rx", slots: "render-slots.tsv",
    prefixes: %w[renderer level textures sprites wad jobs game],
    fields: {
      "sw" => "renderer_sw", "cmap" => "renderer_colormap", "atlas" => "job_executor_atlas",
      "scr" => "renderer_screen", "fuzzoffset" => "job_executor_fuzzoffset", "sprlump" => "sprites_lump",
      "sprflip" => "sprites_flip",
      "wad" => "renderer_wad_data", "centery" => "renderer_centery", "state_sprite" => "renderer_state_sprite",
      "state_frame" => "renderer_state_frame", "width" => "jobs_width", "flat" => "job_executor_flatatlas",
      "spr_lumppos" => "sprites_lumppos", "spr_lumpnum" => "sprites_lumpnum", "spr_lumpend" => "sprites_lumpend",
      "exec_atlas_size" => "job_executor_atlas_size", "exec_flat_size" => "job_executor_flat_size",
      "exec_width" => "job_executor_width", "exec_centery" => "job_executor_centery",
      "exec_vwx" => "job_executor_viewwindowx", "exec_vwy" => "job_executor_viewwindowy",
      "zero_slots" => "derived:render-zero.tsv", "rv_caps" => "core_render_caps", "bsp_stack" => "core_bsp_stack",
      "sb_shadow" => "core_sb_shadow",
      "sb_backing" => "status_bar_backing", "old_arms" => "status_bar_old_arms",
      "old_keybox" => "status_bar_old_keybox", "keyboxes" => "status_bar_keyboxes",
      "tallnum" => "status_bar_tallnum", "shortnum" => "status_bar_shortnum", "armsgray" => "status_bar_armsgray",
      "faces" => "status_bar_faces", "keys" => "status_bar_keys", "tallw" => "status_bar_tallw",
      "shortw" => "status_bar_shortw", "sbar" => "status_bar_sbar", "tallpercent" => "status_bar_tallpercent",
      "armsbg" => "status_bar_armsbg", "pl_ammo" => "game_pl_ammo", "pl_maxammo" => "game_pl_maxammo",
      "pl_weaponowned" => "game_pl_weaponowned",
      "font_lump" => "hud_font_lump", "hud_texts" => "hud_texts",
      "hud_text_ofs" => "hud_text_ofs", "hud_sw" => "hud_sw", "hud_scale" => "hud_scale"
    },
    buffers: %w[],
    scalars: %w[first health armorpoints ammokind viewx viewy viewz viewangle],
    comment: <<~TXT,
      # `doom_core_render`: bin/doom.rb's frame from `r.clear_screen` to `hud.draw`,
      # in job mode 0 (decision 0008, 2026-10-21): the view, drawn directly in
      # that mode; the status bar, onto the screen or,
      # when the screen is scaled, onto its 320x200 shadow and copied; the HUD's
      # message. Full stores the weapon sprites and the extra light into their
      # fields before the call (their setters are absorbed), and hands over the
      # values bin/doom.rb passes as arguments. `Renderer#draw_jobs_cpu` is not
      # called: bin/doom.rb reaches it only under -gpu, job mode 4. Answers the
      # frame sequence number.
    TXT
    body: <<~RUBY,
      rv_caps[RV_CAP_WAD] = n_wad
      rv_caps[RV_CAP_LUMPS] = n_lump_pos
      rv_caps[RV_CAP_ZERO_SLOTS] = n_zero_slots
      rv_caps[RV_CAP_BSP] = n_bsp_stack
      if first != 0
        CALL dc_rv_clear_screen()
      end
      CALL dc_rv_render_player_view(viewx: viewx, viewy: viewy, viewz: viewz, viewangle: viewangle)
      if resscale[0] == 1
        CALL dc_draw_statusbar(screen: @scr, backing: @sb_backing, wad: @wad, tallw_b: @tallw, shortw_b: @shortw, sbar_b: @sbar, tallpercent_b: @tallpercent, armsbg_b: @armsbg, ammo: @pl_ammo, maxammo: @pl_maxammo, weaponowned: @pl_weaponowned, i_firsttime: rx[R_SB_FIRSTTIME], i_old_armsbg: rx[R_SB_OLD_ARMSBG], i_old_face: rx[R_SB_OLD_FACE], i_faceindex: rx[R_SB_FACEINDEX], i_notdeathmatch: rx[R_SB_NOTDEATHMATCH], health: health, armorpoints: armorpoints, ammokind: ammokind)
      else
        CALL dc_draw_statusbar(screen: @sb_shadow, backing: @sb_backing, wad: @wad, tallw_b: @tallw, shortw_b: @shortw, sbar_b: @sbar, tallpercent_b: @tallpercent, armsbg_b: @armsbg, ammo: @pl_ammo, maxammo: @pl_maxammo, weaponowned: @pl_weaponowned, i_firsttime: rx[R_SB_FIRSTTIME], i_old_armsbg: rx[R_SB_OLD_ARMSBG], i_old_face: rx[R_SB_OLD_FACE], i_faceindex: rx[R_SB_FACEINDEX], i_notdeathmatch: rx[R_SB_NOTDEATHMATCH], health: health, armorpoints: armorpoints, ammokind: ammokind)
        CALL dc_rv_blit_scale(dst: @scr, src: @sb_shadow, dstw: sw[0], srcw: 320, sx: 0, sy: 168, w: 320, h: 32, s: resscale[0])
      end
      CALL dc_draw_hud(screen: @scr, wad: @wad, text: @hud_texts, text_ofs: @hud_text_ofs, sw_b: @hud_sw, scale_b: @hud_scale, i_message: rx[R_HUD_MESSAGE], i_message_on: rx[R_HUD_MESSAGE_ON])
      state[rx[R_FRAME]] = state[rx[R_FRAME]] + 1
      state[rx[R_FRAME]]
    RUBY
  },
].freeze

# --- expansion ------------------------------------------------------------------
def split_args(s)
  out = []
  depth = 0
  cur = +""
  s.each_char do |ch|
    if "([".include?(ch) then depth += 1
    elsif ")]".include?(ch) then depth -= 1
    end
    if ch == "," && depth.zero?
      out << cur.strip
      cur = +""
    else
      cur << ch
    end
  end
  out << cur.strip unless cur.strip.empty?
  out
end

src_out = +""
fields_out = []
ENTRIES.each do |e|
  used = []
  add = ->(b) { used << b unless used.include?(b) || b == "state" || b == e[:index] }
  e[:buffers].each(&add)
  body = e[:body].gsub(/CALL (dc_\w+)\((.*)\)$/) do
    callee = Regexp.last_match(1)
    given = split_args(Regexp.last_match(2)).to_h do |kv|
      k, v = kv.split(":", 2).map(&:strip)
      [k, v]
    end
    raw.key?(callee) or abort("core-entries: #{e[:name]} calls #{callee}, which the port does not define")
    params = raw[callee][0]
    (given.keys - params).empty? or
      abort("core-entries: #{e[:name]}: #{callee} has no parameter #{(given.keys - params).join(', ')}")
    args = params.map do |p|
      v = given[p]
      if v.nil?
        buf[callee][p] or abort("core-entries: #{e[:name]}: #{callee}'s #{p} is not a buffer and is not given")
        p == "gx" || p == "rx" || p == "xi" and
          (p == e[:index] or abort("core-entries: #{e[:name]}: #{callee} takes the index table #{p}"))
        add.call(p)
        p
      elsif v.start_with?("@")
        buf[callee][p] or abort("core-entries: #{e[:name]}: #{callee}'s #{p} is not a buffer, and @#{v} is one")
        add.call(v[1..])
        v[1..]
      else
        v
      end
    end
    "#{callee}(#{args.join(', ')})"
  end
  body =~ /CALL / and abort("core-entries: #{e[:name]}: a CALL the expansion did not read")
  sig = ["state", "n_state", e[:index], "n_#{e[:index]}"] + used.flat_map { |b| [b, "n_#{b}"] } + e[:scalars]
  # EVERY BUFFER THE BODY NAMES DIRECTLY IS A PARAMETER: a name indexed, or a
  # count `n_NAME`, that no call binds and `buffers:` does not list would be a
  # buffer the entry reads without taking it.
  named = body.scan(/\b([a-z_][a-z0-9_]*)\[/).flatten | body.scan(/\b(n_[a-z0-9_]+)\b/).flatten
  (named - sig).empty? or
    abort("core-entries: #{e[:name]}: the body names #{(named - sig).join(', ')}, which is not a parameter " \
          "(list it in buffers:, or pass it to a call)")
  src_out << e[:comment] << "def #{e[:name]}(#{sig.join(', ')})\n" << body.gsub(/^/, "  ").gsub(/^  $/, "") << "end\n\n"

  width = WIDTHS[e[:name]] or abort("core-entries: #{e[:name]}: entries/units.tsv gives it no #width line")
  scalar_t = width == "target" ? "i32" : "i64"
  contract = ["core-contract 1", "root src/packed.rb", "entry #{e[:name]}", "result #{scalar_t}"]
  bind = ->(p, field, element, mode) do
    contract << "param #{p} buffer #{element} #{mode} count n_#{p}" << "param n_#{p} scalar u64"
    fields_out << [e[:name], p, field, element, mode]
  end
  bind.call("state", "core_state", "i64", "inout")
  bind.call(e[:index], "derived:#{e[:slots]}", "i64", "in")
  used.each do |p|
    field = e[:fields][p] || e[:prefixes].map { |x| "#{x}_#{p}" }.find { |k| SCHEMA.key?(k) }
    field or abort("core-entries: #{e[:name]}: #{p} resolves to no field")
    if field.start_with?("derived:")
      bind.call(p, field, "i64", "in")
      next
    end
    s = SCHEMA.fetch(field) { abort("core-entries: #{e[:name]}: #{p} names #{field}, which the schema does not have") }
    mode = ACCESS[[e[:name], field]] or
      abort("core-entries: #{e[:name]}: #{p} is #{field}, and access.tsv gives #{e[:name]} no row for it")
    bind.call(p, field, s[:element], mode)
  end
  e[:scalars].each { |s| contract << "param #{s} scalar #{scalar_t}" }
  File.write(File.join(OUT_DIR, "#{e[:name]}.contract"), "#{contract.join("\n")}\n")
  warn("core-entries: #{e[:name]}: #{used.length} buffer(s), #{e[:scalars].length} scalar(s)")
end

File.write(OUT_SRC, <<~HEAD + src_out.rstrip + "\n")
  # examples/doom/core/src/doomentry.rb — GENERATED by tools/doom/core-entries.rb; do not edit.
  #
  # GPL-derived, from `examples/doom/bin/doom.rb`'s interactive loop, whose order
  # each entry keeps. See ../NOTICE.md and ../sources.tsv.
  #
  # Decision 0008's three entries. Each parameter's resident field is in
  # ../entries/fields.tsv; each contract is ../entries/NAME.contract.

HEAD
File.open(File.join(OUT_DIR, "fields.tsv"), "w") do |io|
  io.puts("# examples/doom/core/entries/fields.tsv — GENERATED by tools/doom/core-entries.rb; do not edit.")
  io.puts("#")
  io.puts("# Which resident field each buffer parameter of the three entries is.")
  io.puts("# `core_state` is the one buffer every scalar field lives in; `derived:TABLE`")
  io.puts("# is an index table Full fills with the core_state slots TABLE names, in")
  io.puts("# order. `mode` is the entry's access.tsv row. tests/doom-core/entry-fields.rb")
  io.puts("# checks every row against the generated layout.")
  io.puts("#")
  io.puts("#entry\tparam\tfield\telement\tmode")
  fields_out.each { |r| io.puts(r.join("\t")) }
end
