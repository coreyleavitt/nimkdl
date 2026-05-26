import std/strutils
import ../src/ast

proc `=copy`*(dst: var KdlNode, src: KdlNode) =
  writeStackTrace()
  quit("KdlNode =copy called! src.name=" & $src.name)

import ../src/parser

var src = ""
for i in 1..3: src.add("level" & $i & " {\n")
src.add("leaf\n")
for _ in 1..3: src.add("}\n")
discard parse(src)
