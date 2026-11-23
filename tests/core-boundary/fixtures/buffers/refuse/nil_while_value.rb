# A refusal fixture for decision 0007 task 3. Not a case in the descriptor
# table: it exists to be rejected, and buffers.sh declares the diagnostic it
# must be rejected with.

# A `while` taken as a value. It DOES fall through, and in Ruby it is nil, so
# meeting it with an integer is a conflict rather than something the other arm
# can paper over. The pair to nil_if_no_else: between them they are the two
# ways a value is nil in this subset, and both are refused by the derivation
# rather than by the producer's hosted-Ruby analysis.

def nil_while_value(link, n_link)
  i = 0
  t = while i < n_link
    i = i + 1
  end
  t
end
