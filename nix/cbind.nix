{ pkgs, src, librln ? null }:

## Hermetic build of the FFI shared library + generated C header.
##
## Mirrors vacp2p/nim-libp2p `nix/cbind.nix` but tailored to
## nim_libp2p_mix_rln.nimble's dep set and a mandatory `librln.a` input.
##
## Deps are declared by `cbind-deps.nix`. That file is a stub in this scaffold
## — its `sha256` values are placeholders. Regenerate them with `nix-prefetch-git`
## against the pinned SHAs before this derivation will evaluate.
##
## `librln`: path to the librln.a static archive from vacp2p/zerokit. Passed in
## from the flake so packaging zerokit stays out of scope here.

let
  cbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  cbindPathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p}") (builtins.attrValues cbindDeps));

  libExt =
    if pkgs.stdenv.hostPlatform.isWindows then "dll"
    else if pkgs.stdenv.hostPlatform.isDarwin then "dylib"
    else "so";

  tinycborVendor = "${cbindDeps.ffi}/ffi/codegen/templates/cpp/vendor/tinycbor";

  librlnLinkArgs =
    if librln == null then
      throw "nim-libp2p-mix-rln/nix/cbind.nix: librln input is required (path to librln.a)"
    else
      "--passL:${librln} --passL:-lm";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-rln-cbind";
  version = "dev";

  inherit src;

  nativeBuildInputs = [
    pkgs.nim-2_2
    pkgs.git
    pkgs.nimble
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    export XDG_CACHE_HOME=$TMPDIR/.cache
    export NIMBLE_DIR=$TMPDIR/.nimble
    export NIMCACHE=$TMPDIR/nimcache

    mkdir -p build $NIMCACHE

    commonArgs="--noNimblePath ${cbindPathArgs} \
      --threads:on --opt:size --noMain --mm:refc -d:metrics \
      -d:chronicles_runtime_filtering=on \
      -d:ffiThreadExitTimeoutMs=5000 \
      -d:libp2p_mix_experimental_exit_is_dest \
      --nimMainPrefix:liblibp2p_mix_rln --nimcache:$NIMCACHE \
      ${librlnLinkArgs}"

    echo "== Building FFI library (dynamic/shared) =="
    nim c $commonArgs --app:lib --out:build/liblibp2p_mix_rln.${libExt} libp2p_mix_rln.nim

    echo "== Building FFI library (static) =="
    nim c $commonArgs --app:staticlib --out:build/liblibp2p_mix_rln.a libp2p_mix_rln.nim

    echo "== Generating C bindings =="
    nim c $commonArgs --app:lib -d:ffiGenBindings -d:targetLang=c \
      -d:ffiOutputDir=c_bindings -d:ffiSrcPath=libp2p_mix_rln.nim \
      -o:/dev/null libp2p_mix_rln.nim
  '';

  installPhase = ''
    mkdir -p $out/lib $out/include
    cp build/liblibp2p_mix_rln.${libExt} $out/lib
    cp build/liblibp2p_mix_rln.a         $out/lib
    cp c_bindings/*.h                    $out/include/
    # libp2p_mix_rln.h includes <tinycbor/cbor.h>; ship the vendored runtime so
    # the installed header set compiles without an external TinyCBOR.
    mkdir -p $out/include/tinycbor
    cp ${tinycborVendor}/* $out/include/tinycbor/
  '';
}
