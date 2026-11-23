# A small shell in Ruby, compiled by Spinel to wasm32, on a terminal whose state
# is libghostty-vt linked into the same module.
require_relative "keys"
require_relative "ghostty"
require_relative "display"
require_relative "life"
require_relative "remote"

class Shell
  PROMPT = "\e[1;32mspinel\e[0m:\e[1;34m~\e[0m$ "
  FILES = {
    "readme.txt" => "Ruby compiled by Spinel, terminal state by libghostty-vt.",
    "notes.txt" => "Everything here runs inside one wasm module."
  }.freeze

  def initialize(screen)
    @screen = screen
    @line = ""
    @history = []
    @cursor = 0
  end

  def run
    @screen.puts("\e[1mSpinel shell on libghostty-vt\e[0m (wasm32). Type help.")
    @screen.write(PROMPT)
    @screen.present
    running = true
    while running
      running = handle(@screen.read)
      @screen.present
    end
  end

  private

  def handle(key)
    case key
    when "\r" then return submit
    when "\x7f" then erase
    when "\e[A", "\eOA" then recall(@cursor - 1)
    when "\e[B", "\eOB" then recall(@cursor + 1)
    else insert(key)
    end
    true
  end

  def submit
    @screen.write("\r\n")
    @history << @line unless @line.empty?
    @cursor = @history.size
    running = execute(@line)
    @line = ""
    @screen.write(PROMPT) if running
    running
  end

  def erase
    return if @line.empty?
    @line = @line[0, @line.size - 1]
    @screen.write("\b \b")
  end

  def recall(position)
    return unless position.between?(0, @history.size)
    @cursor = position
    @screen.write("\b \b" * @line.size)
    @line = @history[position] || ""
    @screen.write(@line)
  end

  def insert(key)
    return unless key.size == 1 && key.ord.between?(32, 126)
    @line += key
    @screen.write(key)
  end

  # Runs one command line and answers whether the shell keeps going.
  def execute(line)
    command, argument = line.split(" ", 2)
    case command
    when nil then nil
    when "help" then help
    when "echo" then @screen.puts(argument || "")
    when "ls" then FILES.each_key { |name| @screen.puts(name) }
    when "cat" then @screen.puts(FILES.fetch(argument || "", "cat: #{argument}: no such file"))
    when "colors" then colors
    when "styles" then styles
    when "fib" then @screen.puts(fib(argument.to_s.to_i).to_s)
    when "glyphs" then glyphs
    when "date" then @screen.puts(Time.now.to_s)
    when "life" then Life.new(@screen).run
    when "clear" then @screen.write("\e[2J\e[H")
    when "exit"
      @screen.puts("bye")
      return false
    else @screen.puts("#{command}: command not found (try help)")
    end
    true
  end

  def help
    [
      "help            this list",
      "echo TEXT       print TEXT",
      "ls / cat FILE   the in-memory files",
      "colors          the 256-colour palette",
      "styles          bold, italic, underline, inverse, wide text",
      "fib N           Fibonacci, computed in Ruby",
      "date            the clock, from the host",
      "life            a full-screen demo (q quits)",
      "glyphs          draw enough distinct glyphs to refill the atlas",
      "clear / exit"
    ].each { |entry| @screen.puts("  " + entry) }
  end

  def colors
    (0...256).each_slice(32) do |row|
      @screen.puts(row.map { |color| "\e[48;5;#{color}m  " }.join + "\e[0m")
    end
  end

  def styles
    @screen.puts("\e[1mbold\e[0m \e[3mitalic\e[0m \e[2mfaint\e[0m \e[4munderline\e[0m \e[9mstrike\e[0m \e[7minverse\e[0m \e[38;2;255;128;0mtruecolor\e[0m")
    @screen.puts("日本語の全角文字 and emoji 🎉 end")
  end

  # Row 0 stays still while the rows below cycle through far more glyphs than
  # the atlas holds, so row 0 only survives if the atlas refresh reaches it.
  def glyphs
    @screen.write("\e[2J\e[H\e[1mAtlas refill\e[0m")
    @screen.present
    @screen.read(1500)
    first = 0x4e00
    40.times do |page|
      text = (0...780).map { |i| [first + page * 780 + i].pack("U") }.join
      @screen.write("\e[3;1H" + text)
      @screen.present
    end
    @screen.write("\e[#{@screen.rows};1H\e[0K")
  end

  def fib(n)
    a, b = 0, 1
    n.times { a, b = b, a + b }
    a
  end
end

screen = Screen.new
if Browser.tw_remote != 0
  Remote.new(screen).run
else
  Shell.new(screen).run
end
