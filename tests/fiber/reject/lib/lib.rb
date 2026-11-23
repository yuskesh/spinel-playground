module Lib
  def self.make
    Fiber.new { 1 }
  end
end
