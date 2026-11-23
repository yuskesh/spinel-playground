# frozen_string_literal: true
#
# 意図非依存の不変量チェック — probe が何を測ろうとしているかを知らないまま、
# それでも「おかしい」と言える 3 つの性質だけを見る。
#
#   決定性  同じ workload を 2 回流したら、同じ件数が出る
#   単調性  filter を狭めたら、件数は増えない
#   停止性  probe を終えた後、BPF の痕跡が残らない
#
# ## なぜ「1 本」であることが要件なのか
#
# 意味論オラクル (results/E325/semcheck.sh) は**意図を符号化する**ので汎用の 1 本が
# 作れず、S1-S21 の 18 変種に増殖した。それは正しい増え方 — 意図は probe ごとに違う。
#
# ここにあるのは逆の性質のものだけを集めてある。上の 3 つは **probe が何を測ろうと
# しているかを一切知らなくても書ける**ので、probe が増えてもこのファイルは増えない。
# **増殖したら、それは意図を混ぜてしまった証拠**であって、機能が足りない証拠ではない。
# 足したくなったら、まず「これは probe を知らずに書けるか」を問うこと。
#
# ## 何を保証しないか
#
# 3 つ全部通っても **probe が意図どおりのものを測っている保証はない**。DNS のつもりで
# 汎用 UDP を測っている probe は、決定的で、単調で、きれいに撤収する。そこは原理的に
# 意図が要る領域で、意味論オラクルか人の仕事のまま。
#
# ## 使い方
#
#   ruby tools/invariants.rb --probe P.rb --workload 'CMD'
#   ruby tools/invariants.rb --probe P.rb --narrower Q.rb --workload 'CMD'
#
#   --probe      対象の .rb
#   --narrower   --probe より条件を狭めた .rb (単調性を見るときだけ)
#   --workload   毎回同じものを流すコマンド。**これが決定的でないと決定性は測れない**
#   --settle     workload 前に待つ秒数 (attach の落ち着き待ち、既定 1)
#   --drain      workload 後に待つ秒数 (drain の追いつき待ち、既定 2)
#   --repeat     決定性の試行回数 (既定 2)
#   --keep       ビルド成果物を消さない
#
# 判定は保守的: 破れは「疑わしい」であって「誤り」ではない。ノイズの多いホストでは
# 決定性は原理的に測れないので、そう言う。exit code は破れがあれば 1 (これは診断でなく
# **検査**なので、収支レポートと違ってゲートにしてよい)。

require "open3"
require "set"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)

def die(msg)
  warn "invariants: #{msg}"
  exit 2
end

# ---- 引数 -------------------------------------------------------------------

opts = { settle: 1, drain: 2, repeat: 2, keep: false }
argv = ARGV.dup
until argv.empty?
  case (a = argv.shift)
  when "--probe"    then opts[:probe]    = argv.shift
  when "--narrower" then opts[:narrower] = argv.shift
  when "--workload" then opts[:workload] = argv.shift
  when "--settle"   then opts[:settle]   = argv.shift.to_f
  when "--drain"    then opts[:drain]    = argv.shift.to_f
  when "--repeat"   then opts[:repeat]   = argv.shift.to_i
  when "--keep"     then opts[:keep]     = true
  when "-h", "--help" then puts File.read(__FILE__)[/\A(#.*\n)+/].gsub(/^# ?/, ""); exit 0
  else die("unknown argument #{a}")
  end
end
die("--probe is required")    unless opts[:probe]
die("--workload is required") unless opts[:workload]
die("#{opts[:probe]}: no such file") unless File.file?(opts[:probe])
die("#{opts[:narrower]}: no such file") if opts[:narrower] && !File.file?(opts[:narrower])
die("--repeat must be >= 2") if opts[:repeat] < 2

# ---- probe を建てて走らせる --------------------------------------------------

def build(rb, outdir)
  cmd = ["ruby", File.join(ROOT, "bin", "spinel-ebpf"), "compile", rb, "-o", outdir, "--build"]
  out, st = Open3.capture2e(*cmd, chdir: ROOT)
  die("build failed for #{rb}\n#{out}") unless st.success?
  bin = File.join(outdir, File.basename(rb, ".rb"))
  die("build produced no binary for #{rb}") unless File.executable?(bin)
  bin
end

# probe を起動 -> settle -> workload -> drain -> SIGTERM。
# 件数は収支レポートの kv 形 (SPNL_CHANNEL_REPORT=kv) から読む。散文は読まない ―
# 散文は改善されるべきもので、そこに機械を張り付けたら改善が破壊的変更になる。
def run_once(bin, workload, settle, drain)
  err_r, err_w = IO.pipe
  pid = Process.spawn(
    { "SPNL_CHANNEL_REPORT" => "kv" }, bin,
    out: File::NULL, err: err_w
  )
  err_w.close
  sleep settle
  system(workload, out: File::NULL, err: File::NULL)
  sleep drain
  Process.kill("TERM", pid)
  Process.wait(pid)
  err = err_r.read
  err_r.close

  counts = {}
  err.each_line do |ln|
    next unless ln.start_with?("spnl.channel ")
    f = ln.split
    name = f[1]
    kv = f[2..].to_h { |p| k, v = p.split("="); [k, v.to_i] }
    counts[name] = kv
  end
  die("no channel report from #{bin}. does the probe have a ringbuf channel?") if counts.empty?
  counts
end

# ---- 停止性: BPF の痕跡が戻るか ----------------------------------------------
#
# 測っているのは probe ではなく **ホスト全体の BPF 状態**なので、実行窓のあいだに
# 別のものが BPF を load したら、そちらの痕跡も「残留」に見える (実測で確認済み)。
# 静かなホストで測ること。逆に言えば、痕跡ゼロを謳う投下 (E305/E307) の before==after
# と同じ測り方をしている。
#
# bpftool が無いホストではこの不変量だけスキップする (残り 2 つは測れる)。
def bpf_ids
  out, st = Open3.capture2e("bpftool", "prog", "show")
  return nil unless st.success?
  progs = out.scan(/^(\d+):/).flatten.to_set
  out, st = Open3.capture2e("bpftool", "map", "show")
  return nil unless st.success?
  [progs, out.scan(/^(\d+):/).flatten.to_set]
end

# ---- 実行 -------------------------------------------------------------------

results = []   # [name, ok(true/false/nil=skip), detail]
work = opts[:keep] ? File.join(ROOT, "build", "invariants") : Dir.mktmpdir("spnl-inv")
FileUtils.mkdir_p(work)

begin
  puts "invariants: building #{opts[:probe]}"
  wide = build(opts[:probe], File.join(work, "wide"))

  # --- 停止性 ---------------------------------------------------------------
  before = bpf_ids
  runs = []
  opts[:repeat].times do |i|
    puts "invariants: run #{i + 1}/#{opts[:repeat]}"
    runs << run_once(wide, opts[:workload], opts[:settle], opts[:drain])
  end
  after = bpf_ids

  if before.nil? || after.nil?
    results << ["termination", nil, "not measured: bpftool is missing"]
  else
    leaked_p = after[0] - before[0]
    leaked_m = after[1] - before[1]
    if leaked_p.empty? && leaked_m.empty?
      results << ["termination", true, "prog/map returned to the set before the run"]
    else
      results << ["termination", false,
                  "leftover prog=#{leaked_p.to_a.join(',')} map=#{leaked_m.to_a.join(',')} " \
                  "— BPF remains after the probe ended. Either the glue's destructor does not detach, " \
                  "or it is pinned. **This looks at the whole host, so also check that nothing else " \
                  "loaded BPF during the run**"]
    end
  end

  # --- 決定性 ---------------------------------------------------------------
  chans = runs.flat_map(&:keys).uniq
  bad = []
  chans.each do |c|
    ins = runs.map { |r| r.dig(c, "in") || 0 }
    bad << "#{c}: #{ins.join(' / ')}" if ins.uniq.size > 1
  end
  if bad.empty?
    detail = chans.map { |c| "#{c}=#{runs[0].dig(c, 'in')}" }.join(" ")
    results << ["determinism", true, "the same counts in all #{opts[:repeat]} runs (#{detail})"]
  else
    results << ["determinism", false,
                "the counts differ between runs: #{bad.join(', ')} — the probe is nondeterministic (a race, missing initialization), " \
                "or the workload is not deterministic, or the host is not quiet. **Suspect the last two first**"]
  end

  if runs[0].values.all? { |v| v["in"].zero? }
    results << ["precondition", nil,
                "0 records in every run. **Every invariant then holds trivially**, so nothing has been shown. " \
                "Look at the balance report (SPNL_CHANNEL_REPORT, on by default) and get records out first"]
  end

  # --- 単調性 ---------------------------------------------------------------
  if opts[:narrower]
    puts "invariants: building #{opts[:narrower]} (narrower)"
    narrow = build(opts[:narrower], File.join(work, "narrow"))
    puts "invariants: run narrower"
    nr = run_once(narrow, opts[:workload], opts[:settle], opts[:drain])

    # チャネル名は `<unit>_<kind>_events` で unit = .rb のベース名。probe が違えば
    # 名前も違うので、unit を落として kind で対応づける。推測ではなくファイル名から
    # 決まるので、probe の中身を知らずに済む。
    strip = lambda do |rb, h|
      unit = File.basename(rb, ".rb")
      h.to_h { |k, v| [k.sub(/\A#{Regexp.escape(unit)}_/, ""), v] }
    end
    wide_by = strip.(opts[:probe], runs[0])
    narr_by = strip.(opts[:narrower], nr)
    common  = wide_by.keys & narr_by.keys

    if common.empty?
      results << ["monotonicity", nil,
                  "the two probes have no channels in common (#{wide_by.keys.join(',')} / " \
                  "#{narr_by.keys.join(',')}). Check that they use the same kind of emit"]
    else
      viol = common.reject { |c| narr_by[c]["in"] <= wide_by[c]["in"] }
      if viol.empty?
        d = common.map { |c| "#{c}: #{wide_by[c]['in']} -> #{narr_by[c]['in']}" }.join(", ")
        results << ["monotonicity", true, "the narrower one did not increase (#{d})"]
      else
        d = viol.map { |c| "#{c}: #{wide_by[c]['in']} -> #{narr_by[c]['in']}" }.join(", ")
        results << ["monotonicity", false,
                    "the narrower one **increased**: #{d} — either the filter is not working, or the condition " \
                    "meant to narrow lets something else through"]
      end
    end
  end
ensure
  FileUtils.remove_entry(work) if !opts[:keep] && Dir.exist?(work)
end

# ---- 報告 -------------------------------------------------------------------

puts
puts "intent-independent invariants"
broke = 0
results.each do |name, ok, detail|
  mark = ok.nil? ? "--" : (ok ? "OK" : "**")
  broke += 1 if ok == false
  puts format("  %-12s %-8s %s", name, mark, detail)
end
puts
puts "  note: passing all 3 does not guarantee that the probe measures what was intended. " \
     "That needs a semantic check against another implementation, or a person."
exit(broke.zero? ? 0 : 1)
