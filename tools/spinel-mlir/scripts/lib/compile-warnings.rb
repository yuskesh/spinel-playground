# Go oracle: v0.6.0 internal/toolchain/toolchain.go ParseCompileOutput,
# cmd/spinelbpf/build.go addCompileWarnings. No oracle output is injected here.
module CompileWarnings
  class Error < StandardError; end
  FIXES=' — known fixes (bpf-mlir): keep a constant default out of the index, e.g. put the ref.index inside the present region (E274); leave room after a record array up to the next power of two (E285)'.b.freeze
  LOC=/\Aloc\("([^"\n]+)":([0-9]+):([0-9]+)\): (.*)\z/n
  def self.combine(frontend,compiled)
    lines=(frontend.b+compiled.b).lines
    keyed=lines.each_with_index.map do |line,index|
      m=/\Aspinelbpf: warning: (.*?)(?::([0-9]+):([0-9]+))?: conditional (SB[0-9]{3}) \([^\n]+\): [^\n]*\n\z/n.match(line)
      raise Error,'compile-output-frontend-warning-shape: '+line unless m
      [[m[1],m[2].to_i,m[3].to_i,m[4],index],line]
    end
    keyed.sort_by(&:first).map(&:last).join.b
  end
  def self.render(stdout,stderr)
    raise Error,'compile-output-stdout' unless stdout.empty?
    return ''.b if stderr.empty?
    warnings=[]
    stderr.b.delete_suffix("\n").split("\n",-1).each do |line|
      match=LOC.match(line)
      raise Error,'compile-output-location: '+line unless match && !match[1].start_with?('/')
      file,ln,col,message=match.captures
      ln,col=ln.to_i,col.to_i
      if message.start_with?('warning: ')
        warnings<<{file:file,line:ln,col:col,message:message.delete_prefix('warning: '),notes:[]}
      elsif message.start_with?('note: ')
        raise Error,'compile-output-note-before-warning' if warnings.empty?
        warnings.last[:notes]<<" (note at #{file}:#{ln}:#{col}: #{message.delete_prefix('note: ')})".b
      else
        raise Error,'compile-output-severity: '+line
      end
    end
    warnings.map do |w|
      pos=w[:line]==0 ? w[:file] : "#{w[:file]}:#{w[:line]}:#{w[:col]}".b
      'spinelbpf: warning: '.b+pos+': conditional SB021 (CompileWarning): ebpf-compile: '.b+w[:message]+w[:notes].join.b+FIXES+"\n".b
    end.join.b
  end
end
