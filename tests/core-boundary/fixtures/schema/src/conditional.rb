# A definition inside `if false`, written at column 0.  A scan for lines that
# begin with `def ` sees a top-level definition here; the AST does not, because
# the DefNode is a child of the IfNode and never appears in the program's own
# statement list.
if false
def twice(v)
  v + v
end
end
