# A definition inside a heredoc.  It is a string, not a DefNode, but its text
# begins at column 0 with `def `.
TEXT = <<~RUBY
def twice(v)
  v + v
end
RUBY
