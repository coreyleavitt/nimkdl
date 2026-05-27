## Smoke test: scaffold is wired up correctly. Real tests land alongside
## their subsystems as #519+ subissues close.

import std/unittest
import ../src/nkdl

suite "kdl smoke":
  test "library version exported":
    check KdlLibVersion == "0.1.0"
