## Generate the three synthetic fixtures used by the bench as actual
## .kdl files so they can be vendored across all harnesses. Run with
## `nim r benchmarks/fixtures/generate.nim` to (re)materialize them.
##
## The fixtures are deterministic by construction. Committing the
## generated files means every harness (ours, ckdl, knus, facet-kdl,
## kdl-rs) parses byte-identical inputs without each one having to
## re-implement the generator in its own language.

import std/[os, strformat]

proc here(): string = currentSourcePath().parentDir()

proc writeIfChanged(path: string, content: string) =
  if fileExists(path) and readFile(path) == content:
    echo "  unchanged: ", path
    return
  writeFile(path, content)
  echo "  wrote:     ", path, " (", content.len, " bytes)"

# 1. Deep chain (depth 100). The shape that originally caught the
#    O(N^2) Result.get deep-copy regression. Linear nest with one
#    arg + one property per level.
proc deepChain(depth: int): string =
  for i in 1..depth: result.add(&"level{i} arg{i} key{i}={i} {{\n")
  result.add("leaf \"bottom\" depth=" & $depth & "\n")
  for _ in 1..depth: result.add("}\n")

# 2. Tree d=8 b=3 (~9,841 nodes). Mirrors a monorepo workspace or
#    a Kubernetes manifest with nested resources.
proc tree(depth, branch: int, prefix: string): string =
  if depth == 0:
    return &"{prefix}leaf \"x\" idx=0\n"
  for b in 0 ..< branch:
    let name = &"{prefix}n{b}"
    result.add(&"{prefix}{name} arg=\"v\" depth={depth} {{\n")
    result.add(tree(depth - 1, branch, prefix & "  "))
    result.add(&"{prefix}}}\n")

# 3. Flat list of ~100 service nodes. Shape of a typical dependency
#    or service registry.
proc flatDeps(): string =
  result.add("// flat list of ~100 services, common config shape\n")
  for i in 1..100:
    result.add(&"service \"svc-{i}\" port={8000 + i} replicas={(i mod 5) + 1}\n")

# 4. Homogeneous 100-service typed-decode fixture. The shape we
#    measure typed decode against (Vec<Service>, seq[Service]).
proc homogeneousServices(): string =
  # KDL v2 requires `#true` not bare `true`. The bare form errors in
  # ckdl/kdl-rs (and ours, with a useful diagnostic), and silently
  # passes in some non-spec parsers — the difference is itself a useful
  # conformance signal but skews benches. Use `#true` to keep apples
  # comparable.
  for i in 0 ..< 100:
    result.add(&"service \"svc-{i}\" port={8000 + i} replicas={(i mod 5) + 1} enabled=#true\n")

let fixtures = here()
writeIfChanged(fixtures / "deep-chain-100.kdl", deepChain(100))
writeIfChanged(fixtures / "tree-d8-b3.kdl",     tree(8, 3, ""))
writeIfChanged(fixtures / "flat-deps-100.kdl",  flatDeps())
writeIfChanged(fixtures / "homogeneous-services-100.kdl", homogeneousServices())
