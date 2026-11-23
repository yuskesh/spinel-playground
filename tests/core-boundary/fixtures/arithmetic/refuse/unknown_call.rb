# A refusal fixture for decision 0007 task 2. Not a case in the table: it
# exists to be rejected, and arithmetic.sh declares the diagnostic it must be
# rejected with.

# A receiverless call to a name nothing in this source defines. `band` stopped
# being a control for this when the checked mode admitted `&`.

def unknown_call(a, b)
  frobnicate(a) + b
end
