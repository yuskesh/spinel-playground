# frozen_string_literal: true
#
# tests/doom-core/object-relocs.rb — what a CORE object still refers to once built.
#
#   ruby tests/doom-core/object-relocs.rb LLVM_BIN OBJECT...
#
# Prints one line per object: `NAME ok` or `NAME refused <why>`, then one
# `targets` line per object for the record. Exit 0 only if every object is ok.
#
# THE INVARIANT, in the owner's words (decision of 2026-09-18):
#
#   CORE objects must not contain data references whose resolution depends on
#   another object.
#
# An object linked into another image keeps its code as built only if nothing
# in it is left for another object to decide. That is a rule about the TARGET,
# not about the kind of instruction: an object may reference data -- a constant
# pool is data -- as long as the data is its own.
#
# So a relocation is admitted when it is either
#
#   * a BRANCH (R_X86_64_PLT32, R_AARCH64_CALL26, R_AARCH64_JUMP26,
#     ARM64_RELOC_BRANCH26, X86_64_RELOC_BRANCH) to a symbol DEFINED IN THIS
#     OBJECT, or
#   * one half of an ADDRESS-MATERIALISATION PAIR (ARM64_RELOC_PAGE21 with
#     ARM64_RELOC_PAGEOFF12; on ELF R_AARCH64_ADR_PREL_PG_HI21 with an
#     R_AARCH64_*_ABS_LO12_NC) whose halves BOTH resolve to the same symbol
#     defined in this object, or
#   * an x86-64 PC-RELATIVE reference (R_X86_64_PC32) to a symbol defined in
#     this object or to a section this object has.
#
# and refused otherwise. An undefined or external target is refused whatever
# the instruction is; so is anything that reaches outside indirectly -- a GOT
# load, a stub, a thread-local variable -- because the resolution then depends
# on another object by construction. The pair is MATCHED, never counted: a
# PAGE21 with no PAGEOFF12 to the same target, or a pair whose halves name
# different targets, is not the admitted shape.
#
# WHY THE RULE IS BY TARGET. It used to be "a branch and nothing else", which
# held on x86-64 only because the compiler can encode a local constant's
# address without a relocation there. On arm64 the same source materialises the
# address of a constant-pool label in its own object as an ADRP/ADD pair, and
# the old rule refused doom_core_step.o for a reference that never leaves the
# object. That was the guard being narrower than its own intent (decision of
# 2026-09-18, on macOS arm64 evidence).
#
# The same holds on x86-64 once the compiler builds a table. A switch the
# optimiser turns into a jump table (relative entries in .rodata, each a PC32
# to this object's .text, and the code's PC32 to the table) or into a lookup
# table (`.Lswitch.table.*`) refers only to this object's own sections; the
# linker places them, and no other object decides anything. The entries'
# x86-64 objects carry both since their bodies moved to the target's width
# (verify.sh, 89e5ab5). A PC32 to a symbol this object does not define, or to
# a section it does not have, is refused like any other reference outside it.
#
# DEFINED IN THIS OBJECT means the symbol is in this object's own symbol table
# with a definition: llvm-nm prints a type letter other than U, u or w. It is
# not restricted to text: `_entry.t`, a constant-pool label, is type `s`.
BRANCHES = %w[R_X86_64_PLT32 R_AARCH64_CALL26 R_AARCH64_JUMP26 ARM64_RELOC_BRANCH26
              X86_64_RELOC_BRANCH R_ARM_THM_CALL R_ARM_THM_JUMP24].freeze
# Decision 0014 (Cortex-M33, Thumb): an address is materialised as a MOVW/MOVT
# pair, the same shape as arm64's ADRP/ADD; the two halves must name the same
# symbol defined in this object. R_ARM_PREL31 is the unwind index's own
# reference to its own text (.ARM.exidx -> .text), a self-reference by
# construction and admitted as such.
PAGE = %w[ARM64_RELOC_PAGE21 R_AARCH64_ADR_PREL_PG_HI21 R_ARM_THM_MOVW_ABS_NC].freeze
PAGEOFF = %w[ARM64_RELOC_PAGEOFF12 R_AARCH64_ADD_ABS_LO12_NC R_AARCH64_LDST8_ABS_LO12_NC
             R_AARCH64_LDST16_ABS_LO12_NC R_AARCH64_LDST32_ABS_LO12_NC
             R_AARCH64_LDST64_ABS_LO12_NC R_AARCH64_LDST128_ABS_LO12_NC
             R_ARM_THM_MOVT_ABS].freeze
SELF = %w[R_ARM_PREL31].freeze
PCREL = %w[R_X86_64_PC32].freeze
# Named so a refusal says WHY the target is another object's, rather than only
# that the type is not admitted.
INDIRECT = %w[GOT TLV TLS PLT_PAGE STUB].freeze

# Decision 0014: `--extern SYM` names an undefined symbol a BRANCH may target
# -- the entry's declared externs, admitted by exact name, never by prefix.
# A data reference to one is still refused: the rule is about data.
externs = []
while ARGV.first == "--extern"
  ARGV.shift
  externs << (ARGV.shift or abort("object-relocs.rb: --extern needs a symbol"))
end
llvm_bin, *objects = ARGV
llvm_bin && !objects.empty? or abort("usage: object-relocs.rb [--extern SYM]... LLVM_BIN OBJECT...")
def run(*cmd)
  out = IO.popen(cmd, err: [:child, :out], &:read)
  $?.success? or abort("object-relocs.rb: #{cmd.join(' ')} failed:\n#{out}")
  out
end

all_ok = true
targets = []
objects.each do |obj|
  name = File.basename(obj, ".o")
  # Every symbol this object DEFINES, of any kind: a branch's target is text,
  # an address pair's is usually a constant-pool label in a data section.
  defined = run(File.join(llvm_bin, "llvm-nm"), "--defined-only", obj).lines.filter_map do |l|
    f = l.split
    f[-1] if f.length >= 2
  end
  # Every section this object has, by name: a section-relative relocation
  # names the section, which is not a symbol.
  sections = run(File.join(llvm_bin, "llvm-objdump"), "-h", obj).lines.filter_map do |l|
    l =~ /\A\s*\d+\s+(\S+)\s+\h+\s/ && $1
  end
  records = []
  in_table = false
  run(File.join(llvm_bin, "llvm-objdump"), "-r", obj).each_line do |l|
    if l.start_with?("RELOCATION RECORDS FOR")
      in_table = true
    elsif in_table && l =~ /\A[0-9a-fA-F]+\s+(\S+)\s+(\S+)\s*\z/
      records << [$1, $2.sub(/[+-]0x[0-9a-fA-F]+\z/, "")]
    elsif in_table && !l.strip.empty? && !l.start_with?("OFFSET")
      abort("object-relocs.rb: #{obj}: unreadable relocation line: #{l.strip}")
    end
  end

  why = nil
  records.each do |type, sym|
    kind = if BRANCHES.include?(type) then :branch
           elsif PAGE.include?(type) then :page
           elsif PAGEOFF.include?(type) then :pageoff
           elsif SELF.include?(type) then :self
           elsif PCREL.include?(type) then :pcrel
           end
    if kind.nil?
      indirect = INDIRECT.find { |k| type.include?(k) }
      why = indirect ? "#{type} to #{sym} resolves through a #{indirect.downcase}, so another object decides it" :
                       "#{type} is neither a branch, an address pair nor a PC-relative reference"
      break
    end
    next if kind == :branch && externs.include?(sym)
    # A self-reference names a SECTION of this object (.ARM.exidx -> .text),
    # and a PC-relative reference may (.text -> .rodata, a jump table's entry
    # -> .text); sections are not symbols, and a section this object has is
    # its own. One it does not have is no section of this object.
    next if (kind == :self || kind == :pcrel) && sections.include?(sym)
    unless defined.include?(sym)
      why = "#{type} to #{sym}, which this object does not define"
      break
    end
  end
  # The pair is matched, not counted: each PAGE21 needs a PAGEOFF12 to the SAME
  # target. A lone half, or halves naming different targets, is not the shape.
  if why.nil?
    page = Hash.new(0)
    off = Hash.new(0)
    records.each do |type, sym|
      page[sym] += 1 if PAGE.include?(type)
      off[sym] += 1 if PAGEOFF.include?(type)
    end
    (page.keys | off.keys).sort.each do |sym|
      next if page[sym] == off[sym]
      why = "#{sym} has #{page[sym]} page relocation(s) and #{off[sym]} offset(s); " \
            "an address pair is matched, not counted"
      break
    end
  end

  if why
    puts "#{name} refused #{why}"
    all_ok = false
  else
    puts "#{name} ok"
  end
  targets << "targets #{name} #{records.empty? ? '-' : records.map { |t, s| "#{t}:#{s}" }.join(',')}"
end
puts targets
exit(all_ok ? 0 : 1)
