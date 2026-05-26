## Hot-loop driver for perf record: nothing but deep-chain parse.
import std/strformat
import ../src/parser

proc main() =
  var src = ""
  for i in 1..100: src.add(&"level{i} arg{i} key{i}={i} {{\n")
  src.add("leaf \"bottom\" depth=100\n")
  for _ in 1..100: src.add("}\n")
  # 30 seconds of pure deep-chain parsing for good sample density.
  for _ in 1..15000:
    discard parse(src)

main()
