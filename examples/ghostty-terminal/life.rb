# Conway's Game of Life on the alternate screen.
class Life
  # Flat Integer arrays: a nested array literal would make every coordinate, and
  # all the arithmetic it reaches, a boxed value.
  NEIGHBOUR_X = [-1, 0, 1, -1, 1, -1, 0, 1].freeze
  NEIGHBOUR_Y = [-1, -1, -1, 0, 0, 1, 1, 1].freeze

  def initialize(screen)
    @screen = screen
    @seed = 12345
    seed_board
  end

  def run
    @screen.write("\e[?1049h\e[?25l\e[2J")
    generation = 0
    loop do
      if @width != @screen.cols - 2 || @height != @screen.rows - 2
        seed_board
        @screen.write("\e[2J")
      end
      draw(generation)
      @screen.present
      break if @screen.read(60) == "q"
      step
      generation += 1
    end
    @screen.write("\e[?25h\e[?1049l")
  end

  private

  def seed_board
    @width = @screen.cols - 2
    @height = @screen.rows - 2
    @alive = Array.new(@width * @height) { random % 4 == 0 }
  end

  def random
    @seed = (@seed * 1103 + 12345) % 65536
    @seed / 7
  end

  def index(x, y)
    ((y + @height) % @height) * @width + (x + @width) % @width
  end

  def neighbours(x, y)
    count = 0
    NEIGHBOUR_X.size.times do |i|
      count += 1 if @alive[index(x + NEIGHBOUR_X[i], y + NEIGHBOUR_Y[i])]
    end
    count
  end

  def step
    @alive = Array.new(@width * @height) do |i|
      count = neighbours(i % @width, i / @width)
      count == 3 || (count == 2 && @alive[i])
    end
  end

  def draw(generation)
    rows = @alive.each_slice(@width).map { |row| row.map { |live| live ? "#" : " " }.join }
    @screen.write("\e[H\e[36m" + rows.join("\r\n") + "\r\n")
    @screen.write("\e[0;7m generation #{generation}  press q to quit \e[0m")
  end
end
