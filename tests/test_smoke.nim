## Smoke test: scaffold is wired up correctly. Real tests land alongside
## their subsystems as #519+ subissues close.

import std/unittest
import ../src/kdl

suite "kdl smoke":
  test "library version exported":
    check KdlLibVersion == "0.0.1"
