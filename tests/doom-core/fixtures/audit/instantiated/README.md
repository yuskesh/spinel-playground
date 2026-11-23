# One definition reported twice

The reader lists an included module's method once under the module, with the
ast tree, and once per including class, as a separate scope whose nodes carry
that class's resolved types and no ast node at all. Measured on DOOM: 706
methods-face entries, 556 ast DefNodes, 150 scopes entirely absent from the
ast, 0 scopes partly in it — and 150 is exactly MapMove 27 + Specials 47 +
Enemy 34 + Pspr 24 + Inter 13 + Sight 5, the six modules `Game` includes.

Two things follow, and this fixture holds both.

An implicit call inside the class's family sees both entries. Counting them as
two candidates called 58 call sites ambiguous that are one method; the
instantiation wins, because it is the one that executes.

The instantiated scope carries no receiver link, so it is read from the ast
twin at the same source position. `Elsewhere#helper` is here because matching
the twin by method name alone picked an unrelated class and lost the receiver
for twelve of DOOM's call sites; the twin must come from a module the class
actually includes.
