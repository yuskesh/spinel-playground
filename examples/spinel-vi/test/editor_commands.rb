# spinel-tier: full
# Terminal-independent Phase 3 command semantics. ViTerm is a save seam fake.
module ViTerm
  def self.sp_vi_file_validate_text(text, length); 0; end
  def self.sp_vi_file_save(path, text, length); 0; end
  def self.sp_vi_file_error; ""; end
  # This terminal-independent command differential does not drive search, but
  # its whole-program compilation still sees the Phase 4 call sites.
  def self.sp_vi_bre_find(pattern, text, offset); 1; end
  def self.sp_vi_bre_start; -1; end
  def self.sp_vi_bre_end; -1; end
  def self.sp_vi_bre_error; ""; end
  def self.sp_vi_egc_next(text, length, offset); offset < length ? offset + 1 : length; end
  def self.sp_vi_egc_prev(text, length, offset); offset > 0 ? offset - 1 : 0; end
  def self.sp_vi_egc_width(text, length, offset, column); 1; end
end
require_relative "../lib/editor_ui"

def key(editor, code, raw = 0)
  editor.handle_key(code, raw)
end

def command(editor, text)
  key(editor, 58)
  i = 0
  while i < text.bytesize
    key(editor, text.getbyte(i)); i += 1
  end
  key(editor, 0, 13)
end

def text(editor); editor.table.materialize; end

e = SpinelVi::Editor.new(80, 24, "note", "one\ntwo\n")
key(e, 100); key(e, 100)
puts "dd-normal=#{text(e).inspect}"
key(e, 100); key(e, 108); puts "pending-cancel=#{e.notice.inspect}"
key(e, 117); puts "undo=#{text(e).inspect}"
key(e, 0, 18); puts "redo=#{text(e).inspect}"
key(e, 121); key(e, 121); key(e, 112); key(e, 112)
puts "yy-p-twice=#{text(e).inspect}"
command(e, "q"); puts "dirty-q=#{e.notice.inspect} running=#{e.running}"
command(e, "q!"); puts "qbang=#{e.running}"

empty = SpinelVi::Editor.new(80, 24, "note", "")
key(empty, 100); key(empty, 100); key(empty, 117); key(empty, 0, 18)
puts "dd-empty=#{text(empty).inspect}"

last = SpinelVi::Editor.new(80, 24, "note", "last")
key(last, 100); key(last, 100); puts "dd-eof=#{text(last).inspect}"
key(last, 105); key(last, 65); key(last, 0, 27); key(last, 117)
puts "insert-one-transaction=#{text(last).inspect}"
key(last, 105); key(last, 66); key(last, 0, 27); key(last, 117); key(last, 105); key(last, 67); key(last, 0, 27); key(last, 0, 18)
puts "redo-discard=#{text(last).inspect}"

saved = SpinelVi::Editor.new(80, 24, "note", "ok\n")
command(saved, "w"); puts "write=#{saved.notice.inspect}"
command(saved, "wq"); puts "wq=#{saved.running}"
