# nim-libp2p-mix-rln-ffi

C FFI facade composing [nim-libp2p][libp2p] + [nim-libp2p-mix][mix] +
[mix-rln-spam-protection-plugin][mix-rln] (aka `nim-libp2p-mix-rln`, the
RLN spam-protection Nim library). Produces `liblibp2p_mix_rln.{so,dylib,dll}`
and `libp2p_mix_rln.h` for consumption by [logos-libp2p-mix-rln][logos-mod]'s
C++/Qt Logos Core module.

Modelled on `vacp2p/nim-libp2p`'s `cbind` package. Uses [nim-ffi][nim-ffi]
for pragma-driven codegen of the C header.

## Status

FFI validated end-to-end at runtime:

- Standalone C smoke test: `nim-libp2p-mix-rln-ffi-smoketest-3node-ffi`
  drives 3 nodes purely through the C API, pings across a Sphinx circuit,
  round-trips per-hop RLN proofs.
- Nim integration test: `test_mix_routing_rln` — same but composed
  in-process, useful for iterating on the composition.
- Multi-node e2e through the C++ Logos Core module — see
  [logos-libp2p-mix-rln][logos-mod].

## Build (nix, hermetic)

```sh
nix build .#cbind
# → result/lib/liblibp2p_mix_rln.{so,a}
# → result/include/libp2p_mix_rln.h + tinycbor/
```

**Two temporary overrides are required** until [zerokit PR #436][zerokit-pr]
lands (draft; not for merge — see the PR for why):

```sh
nix build .#cbind \
  --override-input zerokit path:/path/to/zerokit-v2-fork \
  --override-input zerokit/nixpkgs 'github:NixOS/nixpkgs?rev=cd648d6ea62bc0ffba91e61fcfe5e33c1e2004b1'
```

The zerokit v2 fork just needs the two nix packaging changes in the PR:
add the `rln-stateless` output, and pass `--no-default-features` when
`features` is set. The `nixpkgs` pin gives you a `fetch-cargo-vendor-util`
that sets a User-Agent so crates.io doesn't 403.

## Tests

```sh
nix run .#test-mix-routing         # 5-node Sphinx circuit (no RLN)
nix run .#test-mix-routing-rln     # same, with per-hop RLN
nix run .#smoketest-3node-ffi      # C-level 3-node ping through FFI
```

All three use the same overrides as `.#cbind`.

## What's real vs. stubbed

Real, exercised at runtime:
- Full lifecycle (`create` / `start` / `stop` / `destroy`).
- `sendMixMessage` — Sphinx-routed writeLp, optional SURB reply.
- `sendMixMessageToExit` — exit-is-dest routing, no exit multiaddr needed.
- `registerRlnMembership` / `hasRlnMembership`.
- `getNodeInfo(Version | PeerId | Multiaddrs | MixPublicKey)`.
- Multi-node topology: `getLocalMixPeerRecord`, `addMixPeer`,
  `mountReceiver`, `deliverCoordFrame` for shell-driven RLN coord sync.
- Events (via `nim-ffi`'s `{.ffiEvent.}`): `onIncomingMixMessage`,
  `onRlnMembershipRegistered`, `onRlnPublishRequested`.

Stubbed (returns `err("not implemented")`):
- `libp2pMixRlnSendMixSurbReply` — needs the mix reply-store lookup wired.
- `libp2pMixRlnGetNodeInfo(RlnMembershipIndex)` — needs group-manager
  root/index accessor upstream.
- `libp2pMixRlnListMixPeers` — waits on Logos Service Discovery wiring
  (Extensible Peer Records source of truth per LIP LOGOS-MIXNET).

## Layout

```
nim-libp2p-mix-rln-ffi/
├── nim_libp2p_mix_rln_ffi.nimble  # package + buildffi + genbindings_c
├── libp2p_mix_rln.nim             # FFI entry — declareLibrary(), types, procs
├── libp2p_mix_rln/config.nim      # {.ffi.} config schema
├── nix/
│   ├── cbind.nix                  # hermetic build derivation
│   ├── cbind-deps.nix             # 26 pinned deps, real sha256s
│   ├── smoketest-3node-ffi.nix    # C smoke test derivation
│   ├── test-mix-routing.nix       # 5-node Sphinx test (no RLN)
│   └── test-mix-routing-rln.nix   # 5-node Sphinx test with RLN
├── tools/regen-cbind-deps.py      # regenerate cbind-deps.nix after bumping pins
├── flake.nix                      # outputs packages.<system>.{cbind,tests}
├── tests/                         # Nim + C integration tests
├── Makefile
├── UPSTREAM_ISSUES.md             # blockers/gaps found upstream during integration
├── config.nims
├── LICENSE-MIT
└── LICENSE-APACHEv2
```

## Local (non-nix) build

```sh
export LIBRLN_PATH=/path/to/librln.a          # from vacp2p/zerokit
nimble -l setup -y
nim c -d:libp2p_mix_experimental_exit_is_dest \
      --app:lib --threads:on --mm:refc \
      --passL:$LIBRLN_PATH --passL:-lm \
      -o:build/liblibp2p_mix_rln.so \
      libp2p_mix_rln.nim
```

On this machine, `nimble -l setup` currently fails building `testutils`
against nimble's freshly-downloaded copy of nim 2.2.10 (stdlib/compiler
mismatch — likely a nimble bug). If you hit it, delete
`nimbledeps/pkgs2/nim-*` and let subsequent `nimble develop` calls use the
system nim. The nix path avoids this entirely.

[libp2p]: https://github.com/vacp2p/nim-libp2p
[mix]: https://github.com/logos-co/nim-libp2p-mix
[mix-rln]: https://github.com/logos-co/mix-rln-spam-protection-plugin
[logos-mod]: https://github.com/logos-co/logos-libp2p-mix-rln
[nim-ffi]: https://github.com/logos-messaging/nim-ffi
[zerokit]: https://github.com/vacp2p/zerokit
[zerokit-pr]: https://github.com/vacp2p/zerokit/pull/436
