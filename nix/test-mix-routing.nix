{ pkgs, src, librln ? null }:

## Runs tests/test_mix_routing.nim end-to-end: builds it with the same
## `--path:` args cbind.nix uses, then executes it as the derivation's
## `installPhase`, capturing the log into $out/log. Success = derivation
## builds; the log records the actual ping RTT.
##
## Reuses cbind.nix's cbindDeps + natTraversalBuilt setup by re-importing.

let
  # Re-import the same dep set cbind.nix builds against; keeps them in sync.
  rawCbindDeps = import ./cbind-deps.nix { inherit pkgs; };

  natTraversalBuilt = pkgs.stdenv.mkDerivation {
    name = "nim-nat-traversal-with-libs";
    src = rawCbindDeps.nat_traversal;
    nativeBuildInputs = [ pkgs.gnumake pkgs.gcc ];
    dontConfigure = true;
    buildPhase = ''
      (cd vendor/miniupnp/miniupnpc && \
        make CFLAGS="-Os -fPIC" build/libminiupnpc.a)
      (cd vendor/libnatpmp-upstream && \
        make CFLAGS="-Wall -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
          libnatpmp.a)
    '';
    installPhase = ''
      mkdir -p $out
      cp -r . $out
    '';
  };

  cbindDeps = rawCbindDeps // { nat_traversal = natTraversalBuilt; };

  pathArgs =
    builtins.concatStringsSep " "
      (map (p: "--path:${p} --path:${p}/src")
           (builtins.attrValues cbindDeps));

  librlnLinkArgs =
    if librln == null then
      throw "test-mix-routing.nix: librln input is required (path to librln.a)"
    else
      "--passL:${librln} --passL:-lm --passL:-lstdc++";
in
pkgs.stdenv.mkDerivation {
  pname = "nim-libp2p-mix-rln-test-mix-routing";
  version = "dev";

  inherit src;

  nativeBuildInputs = [ pkgs.nim-2_2 ];

  # The test binds an ephemeral loopback TCP port and talks to itself in-process;
  # nix's default sandbox loopback is fine.
  buildPhase = ''
    export HOME=$TMPDIR
    export NIMCACHE=$TMPDIR/nimcache
    mkdir -p $NIMCACHE

    echo "== Building tests/test_mix_routing.nim =="
    nim c --noNimblePath ${pathArgs} \
      --threads:on --mm:refc -d:release \
      -d:chronicles_runtime_filtering=on -d:chronicles_log_level=INFO \
      -d:libp2p_mix_experimental_exit_is_dest \
      ${librlnLinkArgs} \
      --nimcache:$NIMCACHE -o:test_mix_routing \
      tests/test_mix_routing.nim
  '';

  # We RUN the test as part of the build — a passing derivation = a passing
  # test. Output the log so post-hoc inspection is possible.
  installPhase = ''
    mkdir -p $out
    echo "== Running test_mix_routing =="
    ./test_mix_routing 2>&1 | tee $out/log
    cp test_mix_routing $out/
    echo "== PASS ==" | tee -a $out/log
  '';

  # Sandbox doesn't have DNS or outbound net, but loopback works — this test
  # only uses 127.0.0.1.
  __noChroot = false;
}
