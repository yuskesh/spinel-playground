# The terminal attached to a real shell: the bytes come from bridge.rb.
class Remote
  def initialize(screen)
    @screen = screen
  end

  def run
    @screen.connect_replies
    @screen.present
    loop do
      kind = @screen.wait
      break if kind == Screen::CLOSED
      if kind == Screen::DATA
        @screen.write(@screen.payload)
        @screen.present
      elsif kind == Screen::KEY
        bytes = @screen.key_bytes
        Browser.tw_send(bytes, bytes.bytesize) unless bytes.empty?
      elsif kind == Screen::RESIZE
        Browser.tw_resize_shell(@screen.cols, @screen.rows)
      end
    end
  end
end
