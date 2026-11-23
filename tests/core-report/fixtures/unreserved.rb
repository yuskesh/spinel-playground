# A call with twelve arguments, six of them on the stack on x86-64, from a
# callee kept out of line. tests/core-report/run.sh builds it for x86-64 and
# reads the report's `unreserved call frame` evidence.
def uf_twelve(a, b, c, d, e, f, g, h, i, j, k, l)
  s = 0
  t = a
  while t < b
    s = s + (t * c + 1) / (d + 1) - e * f + g * h - i + j * k - l
    s = s + (t * c + 2) / (d + 2) - e * f + g * h - i + j * k - l
    s = s + (t * c + 3) / (d + 3) - e * f + g * h - i + j * k - l
    s = s + (t * c + 4) / (d + 4) - e * f + g * h - i + j * k - l
    t = t + 1
  end
  s
end

def uf_many(x, y)
  uf_twelve(x, y + 1, 1, y, x, 1, y, x, 1, y, x, 1) +
    uf_twelve(x, y + 2, 2, y, x, 2, y, x, 2, y, x, 2) +
    uf_twelve(x, y + 3, 3, y, x, 3, y, x, 3, y, x, 3) +
    uf_twelve(x, y + 4, 4, y, x, 4, y, x, 4, y, x, 4)
end
