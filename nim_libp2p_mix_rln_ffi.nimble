mode = ScriptMode.Verbose

packageName = "nim_libp2p_mix_rln_ffi"
version     = "0.1.0"
author      = "Logos"
description = "C FFI facade composing nim-libp2p, nim-libp2p-mix, and mix-rln-spam-protection-plugin. Produces liblibp2p_mix_rln.{so,dylib,dll} + libp2p_mix_rln.h for consumption by logos-libp2p-mix-rln."
license     = "MIT OR Apache-2.0"

# Direct deps ---------------------------------------------------------------
# `mix_rln_spam_protection` transitively pins `libp2p == 2.1.4` and
# `nim-libp2p-mix#c387ca67cf477dc53ec6228027c45d8eda067917`; that pin
# collapses the diamond dep for us — do NOT also require a different
# libp2p / nim-libp2p-mix version here.
# nim-ffi at the pinned SHA requires nim >= 2.2.6; nim-libp2p/cbind's
# lockfile pins nim to 2.2.10.
requires "nim >= 2.2.6"
requires "chronos >= 4.2.2"
requires "chronicles >= 0.11.0"
requires "results >= 0.4.0"
requires "stew >= 0.4.2"
requires "metrics"
requires "nimcrypto >= 0.6.0"
requires "taskpools >= 0.1.0"

# nim-ffi: pragmas + codegen for the C header. Pinned to current master head.
# (nim-libp2p/cbind's pin `b95e2b04…` is on an unmerged branch
# `fix/cbor-non-canonical` and nimble's shallow-clone-of-master strategy can't
# resolve it; that fix is present on master as squashed commit `83f1aae`.)
requires "https://github.com/logos-messaging/nim-ffi#b6c17dc822960b626d76d814de90208c0a40a44e"
requires "https://github.com/vacp2p/nim-cbor-serialization#1664160e04d153573373afddc552b9cbf6fbe4dc"

# The RLN plugin drags libp2p 2.1.4 + libp2p_mix into scope; that's the
# entire composition target for this facade.
requires "https://github.com/logos-co/mix-rln-spam-protection-plugin.git#135182b72c16d3bd9c2d06087d84303272e4d1eb"

# Build tasks --------------------------------------------------------------
# Modelled on vacp2p/nim-libp2p `cbind/cbind.nimble`. Two products:
#   `nimble buildffi`      → build/liblibp2p_mix_rln.{so,dylib,dll}
#   `nimble genbindings_c` → c_bindings/libp2p_mix_rln.h
# The nix path (nix/cbind.nix) does the same in a hermetic derivation.
import os, strutils

proc findInstalledPkgDir(prefix: string): string =
  var bases = @[
    "nimbledeps/pkgs2", "nimbledeps/pkgs",
    "../nimbledeps/pkgs2", "../nimbledeps/pkgs",
  ]
  let home = getEnv("HOME")
  if home.len > 0:
    bases.add home & "/.nimble/pkgs2"
  for base in bases:
    if not dirExists(base): continue
    for entry in listDirs(base):
      if entry.extractFilename().startsWith(prefix):
        return entry
  raise newException(
    IOError,
    "could not locate installed package '" & prefix &
      "*'; run `nimble -l setup -y` first",
  )

proc ffiDepPaths(): string =
  " --path:" & findInstalledPkgDir("ffi-") &
  " --path:" & findInstalledPkgDir("cbor_serialization-")

proc libExt(): string =
  when defined(windows): "dll"
  elif defined(macosx): "dylib"
  else: "so"

proc librlnLink(): string =
  # librln.a is not a nimble package — it's a static archive produced by
  # vacp2p/zerokit (Rust). LIBRLN_PATH must point at it; the build fails
  # loudly rather than silently linking without it.
  let p = getEnv("LIBRLN_PATH")
  if p.len == 0:
    raise newException(IOError,
      "LIBRLN_PATH is unset; point it at librln.a from vacp2p/zerokit")
  " --passL:" & p & " --passL:-lm"

proc buildFfiLib() =
  let buildDir = "build"
  if not dirExists(buildDir):
    mkDir(buildDir)
  exec "nim c --out:" & buildDir & "/liblibp2p_mix_rln." & libExt() &
    " --threads:on --app:lib --opt:size --noMain --mm:refc -d:metrics" &
    " -d:chronicles_runtime_filtering=on -d:ffiThreadExitTimeoutMs=5000" &
    " -d:libp2p_mix_experimental_exit_is_dest" &
    librlnLink() & ffiDepPaths() &
    " --nimMainPrefix:liblibp2p_mix_rln --nimcache:nimcache libp2p_mix_rln.nim"

task buildffi, "Build the FFI shared library":
  buildFfiLib()

proc genBindingsFor(lang, outDir: string) =
  exec "nim c --threads:on --noMain --mm:refc -d:metrics --compileOnly" &
    " -d:chronicles_runtime_filtering=on --nimMainPrefix:liblibp2p_mix_rln" &
    " -d:ffiGenBindings -d:targetLang=" & lang & " -d:ffiOutputDir=" & outDir &
    " -d:ffiSrcPath=libp2p_mix_rln.nim" & ffiDepPaths() &
    " --nimcache:nimcache_" & lang & " libp2p_mix_rln.nim"

task genbindings_c, "Generate C bindings (c_bindings/libp2p_mix_rln.h)":
  genBindingsFor("c", "c_bindings")

task genbindings_cddl, "Generate CDDL schema":
  genBindingsFor("cddl", "cddl_bindings")

# `nimble test` — runs every tests/*.nim.
# The mix-routing integration test (no RLN) doesn't need librln, but our .nimble
# transitively drags mix-rln-spam-protection-plugin in, which links against
# librln. Skip the RLN link if a test doesn't reach those symbols by only
# passing --passL when LIBRLN_PATH is set.
task test, "Run integration tests":
  for f in listFiles("tests"):
    let (_, name, ext) = f.splitFile
    if ext != ".nim" or not name.startsWith("test_"):
      continue
    var linkArgs = ""
    let librln = getEnv("LIBRLN_PATH", "")
    if librln.len > 0:
      linkArgs = " --passL:" & librln & " --passL:-lm"
    exec "nim c -r --threads:on --mm:refc" &
      " -d:libp2p_mix_experimental_exit_is_dest" &
      linkArgs & ffiDepPaths() &
      " --nimcache:nimcache_" & name & " tests/" & name & ".nim"
    rmFile "tests/" & name.toExe
