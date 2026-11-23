require 'json'
repo=File.expand_path('..',__dir__)
abort 'compile-warnings-parser-missing' unless File.file?(repo+'/scripts/lib/compile-warnings.rb')
require repo+'/scripts/lib/compile-warnings'
require repo+'/scripts/lib/byte-comparison'
fix=' — known fixes (bpf-mlir): keep a constant default out of the index, e.g. put the ref.index inside the present region (E274); leave room after a record array up to the next power of two (E285)'
ledger=[]
same=lambda do |name,stdout,stderr,want|
  got=CompileWarnings.render(stdout.b,stderr.b)
  abort "#{name}: byte mismatch" unless ByteComparison.equal?(got,want)
  ledger<<{name:name,status:'equal',bytes:got.bytesize}
end
same.call('empty','','','')
same.call('unknown-warning-body','','loc("p.rb":3:5): warning: 未知のwarning' + "\n",
          'spinelbpf: warning: p.rb:3:5: conditional SB021 (CompileWarning): ebpf-compile: 未知のwarning'+fix+"\n")
same.call('notes-and-position','','loc("z.rb":0:2): warning: first'+"\n"+'loc("z.rb":0:9): note: origin'+"\n"+'loc("a.rb":8:1): warning: second'+"\n",
          'spinelbpf: warning: z.rb: conditional SB021 (CompileWarning): ebpf-compile: first (note at z.rb:0:9: origin)'+fix+"\n"+'spinelbpf: warning: a.rb:8:1: conditional SB021 (CompileWarning): ebpf-compile: second'+fix+"\n")
{
  'stdout'=>['x',''],
  'bare-line'=>['','warning: x'],
  'absolute-loc'=>['','loc("/a.rb":1:1): warning: x'],
  'leading-note'=>['','loc("p.rb":1:1): note: x'],
  'remark'=>['','loc("p.rb":1:1): remark: x'],
  'error'=>['','loc("p.rb":1:1): error: x'],
  'blank-line'=>['',"loc(\"p.rb\":1:1): warning: x\n\n"]
}.each do |name,(o,e)|
  begin
    CompileWarnings.render(o.b,e.b)
    abort "#{name}: accepted unknown output shape"
  rescue CompileWarnings::Error => error
    abort "#{name}: unnamed refusal" unless error.message.start_with?('compile-output-')
    ledger<<{name:name,status:'named-rejection',diagnostic:error.message}
  end
end
abort 'compile-warnings-combine-missing' unless CompileWarnings.respond_to?(:combine)
front="spinelbpf: warning: p.rb:4:2: conditional SB013 (ScalarPoly): existing\n"
compiler="spinelbpf: warning: a.rb:9:1: conditional SB021 (CompileWarning): first\n"+
         "spinelbpf: warning: p.rb:4:2: conditional SB021 (CompileWarning): second\n"
abort 'warning-stable-position-order' unless ByteComparison.equal?(CompileWarnings.combine(front,compiler),compiler.lines.first.b+front.b+compiler.lines.last.b)
abort 'warning-empty-combine' unless CompileWarnings.combine(''.b,''.b).empty?
ledger<<{name:'merge-frontend-compiler-by-position-code',status:'equal'}
puts JSON.pretty_generate(ledger)
