# frozen_string_literal: true
#
# tools/app/lib/core_app/session.rb -- an application's `core_session`
# (decision 0021, Clarification of 2026-10-20).
#
# `core_session "<entries dir>"` names the three DOOM entries' contracts
# (examples/doom/core/entries). The build takes the session at open as
# decision 0021's image (`--session-image DIR`, tools/doom/session-image.rb)
# and the entries' objects built apart for the target (`--session-objects
# DIR`: doom_core_*.o, their headers and reports). From those this reads, and
# checks against one another:
#
#   * the image: image.tsv, with image.sha256 checked against the three files;
#   * the contracts: each entry's parameters in order, and entries/fields.tsv,
#     which names the field every buffer parameter is handed;
#
# and generates:
#
#   * `DoomCore.input`, `DoomCore.step` and `DoomCore.render`, which take the
#     entries' scalar arguments only. Their providers are generated here: each
#     hands the entry every buffer at its place in the session, with its count,
#     and answers the entry's 0007 status. They call CORE, which the provider
#     screen of 0014 §6 refuses for every other provider; the three symbols are
#     exempt by name (PROVIDERS) and nothing else is, and in exchange the
#     application's checks require one writing context for the whole session
#     (AppChecks): the context that calls DoomCore writes every session buffer,
#     so an entry of another context may not name one;
#   * `Slot::NAME`, the core_state slot of every scalar field (0014 D5's one
#     level), so the application reads and writes a slot by name;
#   * the session states an application entry names: a parameter named after a
#     writable field (or `core_state`) receives that field's storage. A
#     resource field is read-only and is refused as a parameter;
#   * the C that places the session: the resources read in place at the NOR
#     address of the image's partition, the writable part copied to RAM at boot
#     after its digest and the resources' are checked.
require "digest"
require_relative "app_model"

module CoreApp
  module Session
    class Error < StandardError; end

    ENTRIES = %w[doom_core_input doom_core_step doom_core_render].freeze
    # The DoomCore member each entry is, and the provider symbols the screen
    # exempts: these three and no other.
    MEMBER = { "doom_core_input" => "input", "doom_core_step" => "step", "doom_core_render" => "render" }.freeze
    PROVIDERS = MEMBER.values.map { |m| "spc_session_doomcore_#{m}" }.freeze
    CTYPE = { "u8" => "uint8_t", "i8" => "int8_t", "u16" => "uint16_t", "i16" => "int16_t",
              "i32" => "int32_t", "u32" => "uint32_t", "i64" => "int64_t" }.freeze
    WIDTH = { "u8" => 1, "i8" => 1, "u16" => 2, "i16" => 2, "i32" => 4, "u32" => 4, "i64" => 8 }.freeze
    # The writable part starts on a 4 KiB boundary of the partition after the
    # resources, so the NOR's erase sectors never hold both.
    RW_ALIGN = 4096

    Field = Struct.new(:name, :role, :element, :count, :part, :offset, :bytes, keyword_init: true)
    Param = Struct.new(:name, :kind, :element, :mode, :count_of, :domain, keyword_init: true) do
      def buffer? = kind == :buffer
      def count? = kind == :scalar && !count_of.nil?
    end
    Image = Struct.new(:dir, :fields, :resources_bytes, :writable_bytes, :scratch_bytes, :sha256, :demo, keyword_init: true) do
      def field(name) = fields[name]
      def slots = fields.values.select { |f| f.part == "core_state" }
      # where writable.bin starts in the partition
      def rw_offset = (resources_bytes + RW_ALIGN - 1) / RW_ALIGN * RW_ALIGN
      def partition_bytes = rw_offset + writable_bytes
    end
    Info = Struct.new(:dir, :image, :entries, :fields, keyword_init: true)

    module_function

    def read_image(dir)
      tsv = File.join(dir, "image.tsv")
      raise Error, "#{dir}: no image.tsv; --session-image names the directory tools/doom/session-image.rb wrote" unless File.file?(tsv)
      sums = File.readlines(File.join(dir, "image.sha256"), chomp: true).to_h { |l| d, n = l.split(/\s+/, 2); [n, d] }
      %w[resources.bin writable.bin image.tsv].each do |n|
        raise Error, "#{dir}/image.sha256 names no #{n}" unless sums.key?(n)
        got = Digest::SHA256.file(File.join(dir, n)).hexdigest
        raise Error, "#{dir}/#{n} is sha256 #{got}; image.sha256 says #{sums[n]}" unless got == sums[n]
      end
      fields = {}
      parts = nil
      demo = nil
      File.foreach(tsv) do |l|
        if l.start_with?("#parts\t")
          parts = l.chomp.split("\t").drop(1).to_h { |p| k, v = p.split(" "); [k, Integer(v, 10)] }
          next
        end
        if l.start_with?("#demo\t")
          _, name, off, tics, pal = l.chomp.split("\t")
          demo = { name: name, offset: Integer(off.delete_prefix("offset "), 10), tics: Integer(tics.delete_prefix("tics "), 10),
                   playpal: pal && Integer(pal.delete_prefix("playpal "), 10) }
          next
        end
        next if l.start_with?("#") || l.strip.empty?
        n, role, el, count, part, off, bytes = l.chomp.split("\t")
        raise Error, "#{tsv}: #{n} has element #{el}" unless WIDTH.key?(el)
        fields[n] = Field.new(name: n, role: role, element: el, count: Integer(count, 10), part: part,
                              offset: Integer(off, 10), bytes: Integer(bytes, 10))
      end
      raise Error, "#{tsv}: no #parts line" unless parts
      sizes = { "resources.bin" => File.size(File.join(dir, "resources.bin")), "writable.bin" => File.size(File.join(dir, "writable.bin")) }
      sizes.each { |n, s| raise Error, "#{tsv}: #parts says #{n} is #{parts[n]} byte(s); the file is #{s}" unless parts[n] == s }
      Image.new(dir: dir, fields: fields, resources_bytes: parts["resources.bin"], writable_bytes: parts["writable.bin"],
                scratch_bytes: parts["scratch"], sha256: sums, demo: demo)
    end

    # The parameters of one entry contract, in order.
    def read_contract(path)
      File.readlines(path, chomp: true).filter_map do |l|
        f = l.split(" ")
        next unless f[0] == "param"
        if f[2] == "buffer"
          Param.new(name: f[1], kind: :buffer, element: f[3], mode: f[4], count_of: nil)
        else
          Param.new(name: f[1], kind: :scalar, domain: f[3])
        end
      end.tap do |ps|
        ps.select(&:buffer?).each do |b|
          line = File.readlines(path, chomp: true).find { |l| l.start_with?("param #{b.name} buffer ") }
          cnt = line.split(" ")[6]
          c = ps.find { |p| p.name == cnt } or raise Error, "#{path}: #{b.name} counts #{cnt}, which is not a parameter"
          c.count_of = b.name
        end
      end
    end

    def read(entries_dir, image_dir)
      image = read_image(image_dir)
      fields = {}
      File.foreach(File.join(entries_dir, "fields.tsv")) do |l|
        next if l.start_with?("#") || l.strip.empty?
        e, p, f = l.chomp.split("\t")
        fields[[e, p]] = f
      end
      entries = ENTRIES.to_h do |e|
        path = File.join(entries_dir, "#{e}.contract")
        raise Error, "#{entries_dir}: no #{e}.contract" unless File.file?(path)
        params = read_contract(path)
        params.select(&:buffer?).each do |b|
          f = fields[[e, b.name]] or raise Error, "#{e} #{b.name}: fields.tsv hands it no field"
          img = image.field(f)
          raise Error, "#{e} #{b.name}: fields.tsv hands it #{f}, which the image does not hold" unless img || f == "core_state"
          if img && img.element != b.element
            raise Error, "#{e} #{b.name}: the contract declares #{b.element}; the image holds #{f} as #{img.element}"
          end
        end
        [e, params]
      end
      Info.new(dir: entries_dir, image: image, entries: entries, fields: fields)
    end

    # The scalar parameters of an entry: what DoomCore.<member> takes.
    def scalars(info, entry) = info.entries[entry].select { |p| p.kind == :scalar && p.count_of.nil? }

    # {count parameter => its count in this session}, for an entry.
    def counts(info, entry)
      info.entries[entry].select(&:count?).to_h do |c|
        [c.name, count_expr(info, entry, info.entries[entry].find { |b| b.name == c.count_of })]
      end
    end

    # A report's work expression -- integers, `+`, `*`, `-`, parentheses,
    # `max(...)` and count parameters -- evaluated over `counts`; nil when it
    # names anything else.
    def evaluate_work(expr, counts)
      text = expr.gsub(/\bn_\w+\b/) { |n| counts.key?(n) ? counts[n].to_s : "?" }
      return nil unless text.match?(/\A[\d\s+*\-(),]*(?:max[\d\s+*\-(),]*)*\z/) && !text.include?("?")
      Object.new.instance_eval { def max(*a) = a.max; eval(text) } # rubocop:disable Security/Eval -- the text is checked above
    end

    # The session's package: DoomCore's three members and the Slot constants,
    # in the form Declarations.read_package reads. `bound` is each member's
    # bound clause.
    def package_rb(info, bound:)
      out = +"# Generated by spinel-core-app from core_session -- do not edit.\n"
      out << "# DoomCore: the three entries, scalar arguments only (decision 0021).\n"
      out << "module DoomCore\n"
      ENTRIES.each do |e|
        params = scalars(info, e).map { |p| "#{p.name}: :#{p.domain}" }.join(", ")
        out << "  core_extern :#{MEMBER[e]}, params: {#{params}}, returns: :i32, isr_ok: false,\n"
        out << "              #{bound.call(e)}, provider: \"session.c\"\n"
      end
      out << "end\n"
      if (d = info.image.demo)
        out << "# Image: where the image's demo (#{d[:name]}) is in renderer_wad_data, and its tics.\n"
        out << "module Image\n  DEMO_OFFSET = #{d[:offset]}\n  DEMO_TICS = #{d[:tics]}\n"
        # PLAYPAL in renderer_wad_data (decision 0024's palette message)
        out << "  PLAYPAL_OFFSET = #{d[:playpal]}\n" if d[:playpal]
        out << "end\n"
      end
      out << "# Slot: each scalar field's core_state slot.\n"
      out << "module Slot\n"
      info.image.slots.each { |f| out << "  #{f.name.upcase} = #{f.offset / 8}\n" }
      out << "end\n"
      out
    end

    # The session states an entry parameter names: [name, element, count,
    # where]. core_state is the slot area at the start of writable.bin. A
    # resource is admitted read-only (the coordinator's decision of 2026-10-20, within
    # 0021's rule that resources are read-only): `readonly` is set, and the
    # build refuses an entry whose kernel report says it writes one.
    def state_for(info, name)
      img = info.image
      if name == "core_state"
        n = img.slots.size
        return { element: "i64", count: n, part: "writable", offset: 0 }
      end
      f = img.field(name) or return nil
      raise Error, "#{name} is a derived index table of the entries, not a field" if f.part == "derived"
      raise Error, "#{name} is a core_state slot; read it as core_state[Slot::#{name.upcase}]" if f.part == "core_state"
      raise Error, "#{name} is scratch: its bytes are undefined between the entries" if f.part == "scratch"
      return { element: f.element, count: f.count, part: "resource", offset: f.offset, readonly: true } if f.part == "resource"
      { element: f.element, count: f.count, part: "writable", offset: f.offset }
    end

    # The C of the session: storage, the boot check and copy, and the three
    # providers. `base` is the NOR address of the image's partition.
    # `failure_sites` (a debugging aid): a provider whose entry answers
    # nonzero records the first such call's entry, status and site for main.
    # `dtcm`: the writable fields core_session keeps in the data TCM (0021,
    # the screen in DTCM): each is its own array there, filled from the NOR's
    # writable part at boot with the rest of it, and the entries are given
    # that array, not its place in spc_session_rw.
    def c_source(info, base:, id:, failure_sites: false, dtcm: [])
      img = info.image
      dtcm.each { |f| raise Error, "dtcm: #{f} is not a writable field of the image" unless img.field(f)&.part == "writable" }
      @dtcm = dtcm
      out = +"/* Generated by spinel-core-app from core_session -- do not edit.\n"
      out << " *\n * The session of decision 0021: the resources read in place at the NOR\n"
      out << " * address of the image's partition, the writable part copied to RAM at\n"
      out << " * boot, and the three DOOM entries called with every buffer at its place.\n */\n"
      out << "#include <stdint.h>\n"
      out << "#include <zephyr/linker/section_tags.h>\n" unless dtcm.empty?
      ENTRIES.each { |e| out << "#include \"#{e}.h\"\n" }
      if failure_sites
        out << "\n/* failure sites (main.c): the first failed call, printed once by main */\n"
        out << "extern const char *volatile spc_fs_entry;\nextern volatile int32_t spc_fs_status;\nextern volatile int32_t spc_fs_site;\n"
        ENTRIES.each { |e| out << "extern int32_t spinel_core_#{e}_failure_site;\n" }
      end
      out << "\n#define SPC_SESSION_BASE ((const uint8_t *)#{format('0x%08xu', base)})\n"
      out << "#define SPC_SESSION_RES_BYTES #{img.resources_bytes}u\n"
      out << "#define SPC_SESSION_RW_OFFSET #{img.rw_offset}u\n"
      out << "#define SPC_SESSION_RW_BYTES #{img.writable_bytes}u\n"
      out << "#define SPC_SESSION_SCRATCH_BYTES #{[img.scratch_bytes, 8].max}u\n\n"
      out << "/* the build's identity (session_steps.rb's session_id), printed at boot */\n"
      out << "const char spc_session_id[] = \"#{id}\";\n\n"
      out << "uint8_t spc_session_rw[SPC_SESSION_RW_BYTES] __attribute__((aligned(8)));\n"
out << "static uint8_t spc_session_scratch[SPC_SESSION_SCRATCH_BYTES] __attribute__((aligned(8)));\n\n"
unless dtcm.empty?
  out << "/* core_session's dtcm: fields, in the data TCM; filled at boot */\n"
  dtcm.each do |f|
    fld = img.field(f)
    out << "__dtcm_noinit_section uint8_t spc_dtcm_#{f}[#{fld.count * WIDTH.fetch(fld.element)}u] __attribute__((aligned(8)));\n"
  end
  out << "\n"
end
      %w[resources.bin writable.bin].each do |n|
        hex = img.sha256[n]
        bytes = hex.scan(/../).map { |b| "0x#{b}" }.join(", ")
        out << "static const uint8_t spc_session_sha_#{n.split('.').first}[32] = { #{bytes} };\n"
      end
      out << "\n" << SHA256_C << "\n"
      out << <<~C
        /* Before the first tic: the resources and the writable part in the NOR
         * must be the image this build was made from, or nothing runs. Answers 0
         * when both digests match and the writable part is in RAM. */
        int32_t spc_session_load(void)
        {
        	uint8_t d[32];
        	spc_session_sha256(SPC_SESSION_BASE, SPC_SESSION_RES_BYTES, d);
        	for (unsigned i = 0; i < 32u; i++)
        		if (d[i] != spc_session_sha_resources[i])
        			return 1;
        	spc_session_sha256(SPC_SESSION_BASE + SPC_SESSION_RW_OFFSET, SPC_SESSION_RW_BYTES, d);
        	for (unsigned i = 0; i < 32u; i++)
        		if (d[i] != spc_session_sha_writable[i])
        			return 2;
        	for (uint32_t i = 0; i < SPC_SESSION_RW_BYTES; i++)
        		spc_session_rw[i] = SPC_SESSION_BASE[SPC_SESSION_RW_OFFSET + i];
      C
      dtcm.each do |f|
        fld = img.field(f)
        out << "\tfor (uint32_t i = 0; i < sizeof spc_dtcm_#{f}; i++) /* #{f}, in the data TCM */\n"
        out << "\t\tspc_dtcm_#{f}[i] = SPC_SESSION_BASE[SPC_SESSION_RW_OFFSET + #{fld.offset}u + i];\n"
      end
      out << "\treturn 0;\n}\n\n"
      ENTRIES.each do |e|
        sc = scalars(info, e)
        sig = sc.map { |p| "#{CTYPE.fetch(p.domain)} #{p.name}" }
        # the result's type is the contract's: i32 for an entry at the
        # target's width, i64 for one still at int64 (decision 0022)
        rt = File.read(File.join(info.dir, "#{e}.contract"))[/^result (\S+)$/, 1] or raise Error, "#{e}.contract has no result"
        out << "int32_t spc_session_doomcore_#{MEMBER[e]}(#{sig.empty? ? 'void' : sig.join(', ')})\n{\n\t#{CTYPE.fetch(rt)} result;\n"
        out << (failure_sites ? "\tint32_t st = spinel_core_#{e}(\n" : "\treturn spinel_core_#{e}(\n")
        args = info.entries[e].map do |p|
          if p.buffer?
            "\t\t#{buffer_expr(info, e, p)}"
          elsif p.count?
            "\t\t#{count_expr(info, e, info.entries[e].find { |b| b.name == p.count_of })}u"
          else
            "\t\t#{p.name}"
          end
        end
        out << (args + ["\t\t&result"]).join(",\n") << ");\n"
        if failure_sites
          out << "\tif (st != 0 && spc_fs_status == 0) {\n\t\tspc_fs_site = spinel_core_#{e}_failure_site;\n" \
                 "\t\tspc_fs_entry = \"#{e}\";\n\t\tspc_fs_status = st;\n\t}\n\treturn st;\n"
        end
        out << "}\n\n"
      end
      out
    end

    def buffer_expr(info, entry, b)
      f = info.fields[[entry, b.name]]
      const = b.mode == "in" ? "const " : ""
      cast = "(#{const}#{CTYPE.fetch(b.element)} *)"
      return "#{cast}spc_session_rw" if f == "core_state"
      img = info.image.field(f)
      case img.part
      when "resource", "derived" then "#{cast}(SPC_SESSION_BASE + #{img.offset}u)"
      when "writable" then (@dtcm || []).include?(f) ? "#{cast}spc_dtcm_#{f}" : "#{cast}(spc_session_rw + #{img.offset}u)"
      when "scratch" then "#{cast}(spc_session_scratch + #{img.offset}u)"
      else raise Error, "#{entry} #{b.name}: #{f} is in part #{img.part}"
      end
    end

    def count_expr(info, entry, b)
      f = info.fields[[entry, b.name]]
      f == "core_state" ? info.image.slots.size : info.image.field(f).count
    end

    SHA256_C = <<~C
      /* SHA-256 (FIPS 180-4), for the boot check alone. */
      static const uint32_t spc_session_k[64] = {
      	0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u, 0x923f82a4u, 0xab1c5ed5u,
      	0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u, 0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u,
      	0xe49b69c1u, 0xefbe4786u, 0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
      	0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u, 0x06ca6351u, 0x14292967u,
      	0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u, 0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u,
      	0xa2bfe8a1u, 0xa81a664bu, 0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
      	0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au, 0x5b9cca4fu, 0x682e6ff3u,
      	0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u, 0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u,
      };
      static uint32_t spc_session_ror(uint32_t x, unsigned n) { return (x >> n) | (x << (32u - n)); }
      static void spc_session_compress(uint32_t h[8], const uint8_t *p)
      {
      	uint32_t w[64];
      	for (unsigned i = 0; i < 16; i++)
      		w[i] = ((uint32_t)p[4 * i] << 24) | ((uint32_t)p[4 * i + 1] << 16) | ((uint32_t)p[4 * i + 2] << 8) | (uint32_t)p[4 * i + 3];
      	for (unsigned i = 16; i < 64; i++)
      		w[i] = w[i - 16] + (spc_session_ror(w[i - 15], 7) ^ spc_session_ror(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 7] +
      		       (spc_session_ror(w[i - 2], 17) ^ spc_session_ror(w[i - 2], 19) ^ (w[i - 2] >> 10));
      	uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
      	for (unsigned i = 0; i < 64; i++) {
      		uint32_t t1 = k + (spc_session_ror(e, 6) ^ spc_session_ror(e, 11) ^ spc_session_ror(e, 25)) + ((e & f) ^ (~e & g)) + spc_session_k[i] + w[i];
      		uint32_t t2 = (spc_session_ror(a, 2) ^ spc_session_ror(a, 13) ^ spc_session_ror(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
      		k = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
      	}
      	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += k;
      }
      static void spc_session_sha256(const uint8_t *p, uint32_t n, uint8_t out[32])
      {
      	uint32_t h[8] = { 0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au, 0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u };
      	uint8_t tail[128];
      	uint32_t full = n / 64u, rest = n - 64u * (n / 64u);
      	for (uint32_t i = 0; i < full; i++)
      		spc_session_compress(h, p + 64u * i);
      	for (uint32_t i = 0; i < 128u; i++)
      		tail[i] = i < rest ? p[64u * full + i] : 0u;
      	tail[rest] = 0x80u;
      	uint32_t blocks = rest + 9u <= 64u ? 1u : 2u;
      	uint64_t bits = (uint64_t)n * 8u;
      	for (unsigned i = 0; i < 8; i++)
      		tail[64u * blocks - 1u - i] = (uint8_t)(bits >> (8u * i));
      	for (uint32_t i = 0; i < blocks; i++)
      		spc_session_compress(h, tail + 64u * i);
      	for (unsigned i = 0; i < 8; i++)
      		for (unsigned j = 0; j < 4; j++)
      			out[4 * i + j] = (uint8_t)(h[i] >> (24u - 8u * j));
      }
    C
  end
end
