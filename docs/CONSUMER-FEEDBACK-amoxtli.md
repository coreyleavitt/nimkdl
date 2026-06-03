# nkdl API feedback — from the amoxtli migration

**Author:** amoxtli (first real external consumer)
**Date:** 2026-06-02
**Context:** amoxtli is migrating off the in-tree `lib/kdl` onto the
extracted-and-revised standalone `nkdl` package. This document records
every friction point the migration hit, tied to concrete call sites, so
nkdl can be fixed in one pass instead of piecemeal workarounds leaking
back into the consumer.

amoxtli is a deliberately demanding consumer: it declares all its decode
types **by hand with explicit `*` exports** and explicit `deriveDecode(T)`
calls (it does **not** use the `kdl:` block), it decodes **heterogeneous
multi-section config files**, and it renders **line/col diagnostics** for
user-authored KDL. Those three usage patterns are where nkdl's redesign
bites.

---

## What migrated cleanly (the boundary)

So the fix-owner knows what's *not* broken:

- Whole-file typed decode: `decode[Rule](body)` and `decode[seq[Policy]](body)`. ✅
- Compile-time embed of builtins: `embed[Rule]("…kdl")` (modulo the
  return-type change, item E). ✅
- Pragmas: `kdlNode / kdlArg / kdlProp / kdlChild / kdlSkip / kdlRename`
  all decode-compatible. ✅
- AST accessors: `doc.node`, `doc.nodes`, `node.child`, `node.children`,
  `node.arguments`, `doc.resolveName`, `KdlValue.kind`/`kvString`/`strVal`. ✅
- `parse` / `parseAll` keep the `sourcePath` parameter. ✅

The rules/policy subsystem (the feature work that triggered this) is
fully nkdl-native. **Everything below is in `config.nim`,
`permission_hook.nim`, `resolver.nim`, and `cve_gate.nim`** — the
config-shaped and diagnostic-shaped consumers.

---

## Summary

| # | Issue | Severity | Blocks migration? |
|---|-------|----------|-------------------|
| **A** | No node-based decode (`kdlDecodeImpl(target, node, doc)` removed; only cursor-over-source) | **CRITICAL** | **Yes** — config + hook loaders |
| **B** | `ParseError` is no longer self-describing: lost line/col, needs source re-passed | **HIGH** | No (workaroundable, ugly) |
| **C** | `decode`/`decodeAll`/`embed` dropped the `sourcePath` param (asymmetric with `parse`) | **HIGH** | No |
| **D** | `deriveDecode` mis-handles **exported fields carrying a pragma** (`field* {.k.}`) | **MEDIUM** | Was yes — you hot-fixed it; needs a regression test + the general case |
| **E** | `embed[T]` silently changed `Result[T]` → `T`; README + module-doc still show `.get` | **MEDIUM** | No (compile error, loud) |
| **F** | `kdl:` block force-emits `deriveEncode` — hostile to decode-only variant schemas | **MEDIUM** | No (we avoid the block) |
| **G** | No public node-decode surface + `kdlDecode` is effectively internal | **LOW** | Compounds A |
| **H** | `parse`/`decode` aren't `{.raises: [].}`; consumers wrap in `except Exception` | **LOW–MED** | No |

---

## A. CRITICAL — no node-based decode

**lib/kdl had:**
```nim
proc kdlDecodeImpl(target: var T, node: KdlNode, doc: KdlDoc): Result[void, ParseError]
```
Decode a single **already-parsed** `KdlNode` into a typed value.

**nkdl has only:** the generated `kdlDecode(v: var T; c: var StringCursor)`
(cursor-over-source) and the top-level `decode[T](src)` / `decode[seq[T]](src)`
that run a cursor from the **start of a source string**. There is no way
to say "decode *this* pre-parsed node into `T`." (`grep decodeNode|fromNode|decodeChild` → none.)

**Why this is fundamental, not niche:** the canonical way to load a config
file with **heterogeneous top-level sections** is: parse once → walk
top-level nodes → dispatch by name → decode each node into its own field.
nkdl's whole-source `decode[T]` (single node of one type) and
`decode[seq[T]]` (many nodes of one type) **cannot express a doc whose
top-level nodes are different types**.

**amoxtli call sites:**
- `src/config.nim:350–404` — `applyDoc` decodes 9 distinct sections
  (`daemon`, `provider`, `permissions`, `git`, `convergence`, `runtime`,
  `sandbox`, `ui`, `mcp`) out of one file:
  ```nim
  for n in doc.nodes:
    case doc.resolveName(n)
    of "daemon":   let r = kdlDecodeImpl(cfg.daemon, n, doc); ...
    of "provider": let r = kdlDecodeImpl(cfg.provider, n, doc); ...
    # …  + manual child-walks for cap-add / devices / mcp args, and
    #     "unknown top-level node" warnings for forward-compat.
  ```
- `src/cli/permission_hook.nim:67–69` — pull one `hook` node out of a doc:
  ```nim
  let hookOpt = doc.node("hook")
  let r = kdlDecodeImpl(result, hookOpt.get, doc)
  ```

**Requested fix (in priority order):**
1. **`decodeNode[T](node: KdlNode, doc: KdlDoc): Result[T, ParseError]`** —
   decode a single pre-parsed node into `T`. This is the direct
   replacement and unblocks both consumers as a rename.
2. Optionally **`decodeChild[T](parent: KdlNode, doc: KdlDoc, name: string): Result[T, ParseError]`**
   sugar for the hook case.

Implementation note: `KdlNode.span` already "covers the entire node
including children," so a node→source-slice→cursor adapter is one viable
path; a cursor that can be seeded at a node boundary is cleaner. Either
way the consumer shouldn't have to re-slice source by hand — that's the
workaround we'd otherwise bake into amoxtli, and it belongs in the library.

---

## B. HIGH — `ParseError` is no longer self-describing (lost line/col)

**lib/kdl:** `err.span.start` was a `Position` carrying **`.line` / `.col`
directly**. A `ParseError` was renderable on its own.

**nkdl:** `Span` is `offset`/`length` only. To get line/col you must:
```nim
let (line, col) = buildLineMap(source).lineColOf(err.span.offset)
```
…which requires the **original source string** at the error-rendering
site. That source is frequently **not in scope** where errors are formatted:

- `src/config.nim:282` — the error helper has only `(path, e: ParseError)`,
  no source:
  ```nim
  proc kdlErr(path: string, e: ParseError): ref ConfigError =
    newException(ConfigError, path & " (line " & $e.span.start.line & …)   # was self-contained
  ```
- `src/provider/resolver.nim:152, 288`, `src/daemon/cve_gate.nim:184` —
  same shape; all built single-line `"(line L, col C): hint"` messages.

Because `decode[T](src)` **discards the source binding**, a `ParseError`
returned from `decode` can't render line/col at all unless the caller
separately kept `src` alive and threads it to every error site.

**Requested fix (pick one):**
- Best: have `parse`/`decode` **attach the resolved `(line, col)`** (or a
  ref to the `LineMap`) onto the returned `ParseError`, so `formatError(err)`
  and a plain `$err` work **without re-passing source**.
- Acceptable: a convenience `formatError(err)` overload that's usable when
  the error already carries enough, plus clear docs on the `buildLineMap`
  dance for the offset-only case.

The current design pushes an O(n) `buildLineMap` + source-threading onto
every consumer that wants human diagnostics — which is every consumer with
user-authored KDL.

---

## C. HIGH — `decode`/`decodeAll`/`embed` dropped `sourcePath`

`parse(source, sourcePath = "<input>")` keeps the filename, but:
```nim
proc decode*[T](src: string): Result[T, ParseError]          # no sourcePath
proc decodeAll*[T](src: string): (T, seq[ParseError])        # no sourcePath
proc embed*[T](src: static[string]): T                       # no sourcePath
```
So **decode-path errors have no filename**, and the consumer must
re-attach the path by hand (every amoxtli site wraps with `path & ": …"`).
It's also just **asymmetric** — `parse` takes it, `decode` doesn't, for no
visible reason.

**amoxtli sites that had to drop the arg:** `loader.nim:178`,
`test_kdl_rule_decode.nim:22/57/71/94` (all were `decode[T](body, path)`).

**Requested fix:** add `sourcePath = "<input>"` to `decode`, `decodeAll`,
`embed`, mirroring `parse`. Cheap, removes a whole class of "stitch the
filename back on" boilerplate, and feeds item B.

---

## D. MEDIUM — `deriveDecode` mis-handled exported pragma'd fields (hot-fixed)

You already patched this mid-session; recording it so it gets a
**regression test** and so the general class is covered.

**Symptom:** `deriveDecode(Trigger)` on a variant whose discriminator is an
**exported field with a pragma**:
```nim
Trigger* {.kdlNode: "trigger".} = object
  case kind* {.kdlArg.}: TriggerKind      # exported `kind*` + pragma
```
failed with `Error: undeclared field: 'kind*'` — the `*` export marker was
not stripped, so the generated code referenced `v.\`kind*\``.

**Root cause:** `fieldInfo` (derive_decode.nim ~L85) read the name from
`nnkPragmaExpr[0]` without unwrapping a nested `nnkPostfix` (the `*`). Any
**exported field that also carries a pragma** hit this, not just
discriminators — amoxtli exports *every* field (`id*`, `enabled*`, …), so
this was load-bearing.

**Why nkdl's own tests missed it:** the README/tests drive types through
the **`kdl:` block**, which writes fields **without `*`** and adds exports
itself — so the hand-written-`*`-plus-pragma path was untested. amoxtli
never uses the block (see F), so it exercises exactly that path.

**Requested:** regression tests for hand-declared, **exported**,
pragma-annotated fields — both a plain `kdlProp*` and an exported variant
discriminator `case kind* {.kdlArg.}`. Mirror in `deriveEncode` (same
`fieldInfo` shape there, line ~318).

---

## E. MEDIUM — `embed[T]` return-type change + stale `.get` docs

**lib/kdl:** `embed[T]` returned `Result[T, ParseError]`.
**nkdl:** `embed*[T](src: static[string]): T` — returns `T`, `doAssert`s
internally (CT error on malformed). The new design is *fine* (loud at build
time), but:

1. It's a **silent breaking change** — consumers doing `embed[Rule](…)`
   into a `seq[Result[Rule]]` now get `seq[Rule]` (amoxtli `builtins.nim:40`),
   and anyone calling `.isOk`/`.get` breaks.
2. **The docs are wrong in two places** — both `README.md:45` and the
   module doc `src/nkdl.nim:33` show:
   ```nim
   const builtins = embed[seq[Service]]("services.kdl").get   # .get on a T — won't compile
   ```

**Requested:** fix both docs (drop `.get`); add a one-line CHANGELOG/migration
note ("embed now returns T, not Result[T]").

---

## F. MEDIUM — `kdl:` block force-emits `deriveEncode`

`kdl_block.nim` emits **both** `deriveEncode(T)` *and* `deriveDecode(T)`
for every `{.kdlNode.}` type ("symmetry is the right default"). For a
**decode-only consumer with variant case-object schemas**, that's a bad
default:

- amoxtli's `Trigger` / `PolicyAction` / `Policy` are variant case-objects
  used **decode-only** (rule/policy files are hand-authored + `staticRead`,
  never encoded from Nim values).
- Forcing `deriveEncode` on them adds compile surface for code never called
  and couples the consumer to the encoder's shape limits (your own
  `peEncodeUnsupported` note flags "variant case-object types, Option[T] on
  a kdlArg").

This is *why* amoxtli declares types by hand with explicit `deriveDecode`
instead of the block — which in turn is why it tripped D. The block being
all-or-nothing pushes demanding consumers off the blessed path.

**Requested (pick one):**
- A decode-only block (`kdlDecode:` / `kdl(decodeOnly = true):`), or
- A per-type opt-out pragma (`{.kdlNoEncode.}`) the block honors, or
- Make the block emit `deriveEncode` **lazily**/dead-code-friendly so an
  unused encoder on an unsupported shape doesn't even need to type-check.

---

## G. LOW — no public node-decode surface; `kdlDecode` is effectively internal

Beyond A (the missing entry point), the **public typed-decode surface is
just `decode[T]` / `decodeAll[T]` / `embed[T]`** — all whole-source. The
generated `kdlDecode(v, cursor)` is documented as the under-the-hood
visitor "public consumers route through `decode[T]`." So a consumer holding
a `KdlDoc` (from `parse`) has **no supported way back into typed decode**.
`parse` → walk → `decodeNode` is a completely reasonable pipeline; nkdl
currently supports the first two steps and not the third. (Fold into A's fix.)

---

## H. LOW–MEDIUM — `parse`/`decode` not `{.raises: [].}`

`parse`/`parseAll`/`decode`/`embed` are `{.noSideEffect.}` but carry **no
`{.raises: [].}`**. amoxtli's resolver already wraps `parse` defensively:
```nim
# src/provider/resolver.nim:159
except Exception as e:
  # Lib/kdl's parse + iterator surface currently leaks bare Exception
  # (Defect-ish) on a few corner paths; wrap any leakage…
```
For a parser whose whole contract is "return errors as `Result`," leaking
exceptions/Defects on corner paths is a contract smell.

**Requested:** annotate the public entry points `{.raises: [].}` (or
document precisely what they can raise). If the `noSideEffect` + VM path
makes a full `raises: []` infeasible, say so in the docs so consumers stop
guessing.

---

## Recommended fix order

1. **A** + **G** — `decodeNode[T]` / `decodeChild[T]`. Unblocks the
   migration; everything else is workaroundable.
2. **C** — add `sourcePath` to `decode`/`decodeAll`/`embed`. Trivial, feeds B.
3. **B** — make `ParseError` renderable without re-passing source.
4. **D** — regression tests for exported pragma'd fields (encode side too).
5. **E** — fix the two `.get` docs + changelog note.
6. **F** — decode-only block / `{.kdlNoEncode.}`.
7. **H** — `{.raises.}` annotations or precise docs.

Items A–C are the ones that, if fixed, turn amoxtli's config/hook/resolver
migration from "rework + bespoke helpers" into "rename a few calls."

---

## Appendix — amoxtli's full nkdl API-surface usage

| Symbol | Used at | nkdl status |
|--------|---------|-------------|
| `decode[T](src)` | loader, tests | ✅ (lost `sourcePath`, C) |
| `decode[seq[T]](src)` | (slice-3 policy work) | ✅ |
| `embed[T]("path")` | builtins, tests | ⚠ return type changed (E) |
| `parse(src, path)` | config, resolver, cve_gate, loader | ✅ |
| `kdlDecodeImpl(target, node, doc)` | config ×9, hook | ❌ **removed (A)** |
| `deriveDecode(T)` | types, hook, config | ✅ (D bug on exported fields) |
| `KdlDoc`, `KdlNode`, `KdlValue` | all | ✅ |
| `doc.node(name)` / `doc.nodes` | loader, resolver, cve_gate, config | ✅ |
| `node.child(doc,name)` / `node.children` | loader, config | ✅ |
| `node.arguments` | loader, resolver, cve_gate | ✅ |
| `doc.resolveName(node)` | config, resolver, cve_gate | ✅ |
| `KdlValue.kind` / `kvString` / `strVal` | loader, resolver, cve_gate | ✅ |
| `ParseError.hint` | all error sites | ✅ |
| `ParseError.span.start.line/.col` | config, resolver, cve_gate, loader | ❌ **removed (B)** → `buildLineMap/lineColOf` |
| `Result.isOk/isErr/get/getErr` | all | ✅ |
| pragmas `kdlNode/Arg/Prop/Child/Skip/Rename` | types, config, hook | ✅ |
| `buildLineMap` / `lineColOf` / `formatError` | (new, post-migration) | ✅ (the B workaround) |
