# E093 subject helper -- a REQUIRED file (three lines below the entry) that
# stores into a global.  Proves arenacheck's reach: the AST it reads is the
# entry PLUS every resolved require, the same reach the T-4 reserved-name
# check has (E091).
$e093_store = {}

def e093_remember(k, v)
  $e093_store[k] = v
end
