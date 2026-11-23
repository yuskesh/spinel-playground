Stand-in Zephyr headers for `tests/app/board.sh`: enough declarations for
`clang -fsyntax-only` to parse a generated `board_port.c` and the adapters'
C. They establish that the generated C and the adapters are well-formed C
over the names they use -- a name collision or a type error is caught here
-- and nothing about Zephyr's real API, which Task 10's pipeline compiles
against. Signatures follow Zephyr v4.4.2's headers by name only.
