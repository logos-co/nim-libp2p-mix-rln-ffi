# nim-libp2p-mix-rln

C FFI facade composing [nim-libp2p][libp2p] + [nim-libp2p-mix][mix] +
[mix-rln-spam-protection-plugin][mix-rln]. Produces
`liblibp2p_mix_rln.{so,dylib,dll}` and `libp2p_mix_rln.h` for consumption by
[logos-libp2p-mix-rln][logos-mod]'s C++/Qt module.

Analogous to `vacp2p/nim-libp2p`'s `cbind` package, and modelled on its
build. Uses [nim-ffi][nim-ffi] for pragma-driven codegen of the C header.

## Status: end-to-end nix build working

`nix build .#cbind` produces `liblibp2p_mix_rln.{so,a}` (34 MB shared, 31 MB
static) plus a `libp2p_mix_rln.h` that compiles cleanly as C (round-tripped
with `gcc -c`). Runtime behavior of individual FFI calls hasn't been exercised
yet — that's the next iteration.

What's real:
- Package layout mirrors `nim-libp2p/cbind`.
- Nimble file pins the correct upstream SHAs. The historical libp2p diamond
  dep (mix pinning 2.0.0 / mix-rln pinning 2.1.4) is resolved transitively
  via `mix_rln_spam_protection`, whose `.nimble` already pins `nim-libp2p-mix`
  at SHA `c387ca67…` (which agrees on `libp2p == 2.1.4`).
- Full FFI API surface in [`libp2p_mix_rln.nim`](libp2p_mix_rln.nim):
  `MixRlnConfig` + request/response types + `{.ffiEvent.}` event types
  (`onIncomingMixMessage`, `onRlnMembershipRegistered`,
  `onRlnPublishRequested`) + 11 exported procs.
- Real bodies wired against upstream APIs (verified against
  `nim-libp2p-mix @ c387ca67`):
    - `libp2pMixRlnCreate` — builds Switch + `MixProtocol.new(..., spamProtection = Opt.some(SpamProtection(plugin)), delayStrategy = Opt.some(SpamProtectionDelayStrategy(...)))`; mounts the mix protocol.
    - `libp2pMixRlnStart` / `Stop` / `Destroy` — real switch lifecycle.
    - `libp2pMixRlnSendMixMessage` — `MixProtocol.toConnection(...)` + `writeLp` + `close`; handles `expectReply` + SURB count.
    - `libp2pMixRlnRegisterRlnMembership` / `HasRlnMembership` — `plugin.registerSelf` + `plugin.getMembershipIndex`; emits `onRlnMembershipRegistered`.
    - `libp2pMixRlnGetNodeInfo(Version | PeerId | Multiaddrs)`.
    - `libp2pMixRlnGetCoverTrafficRate` / `SetCoverTrafficRate` (rate is stored; scheduler propagation pending).
- `buildRlnPlugin` bridges the plugin's `setPublishCallback` to the
  `onRlnPublishRequested` FFI event so the C host can forward RLN Relay
  coord traffic wherever it needs to go.
- `nix/cbind-deps.nix` has real `sha256` values for all 26 transitive deps
  (merged from `vacp2p/nim-libp2p @ v2.1.4/nix/deps.nix` + `master/nix/cbind-deps.nix`
  + fresh `nix-prefetch-git` for libp2p / libp2p_mix / mix-rln plugin).
  Regenerate with `tools/regen-cbind-deps.py`.
- `flake.nix` inputs `github:vacp2p/zerokit` and passes
  `${zerokit.packages.<system>.rln}/lib/librln.a` into `cbind.nix` — no
  manual librln packaging needed. Verified out-of-band: `cargo build --release`
  in `zerokit/rln/` produces a 42 MB `librln.a`, so the input path is real.

What's still stubbed (returns `err("not implemented")`):
- `libp2pMixRlnSendMixSurbReply` — needs the mix reply-store lookup wired.
- `libp2pMixRlnGetNodeInfo(MixPublicKey | RlnMembershipIndex)` — need
  accessors on `MixNodeInfo.mixPubKey` and the group-manager root/index.
- `libp2pMixRlnListMixPeers` — waits on Logos Service Discovery wiring
  (Extensible Peer Records source of truth per LIP LOGOS-MIXNET).

## Build

**Recommended:** hermetic nix build. Verified end-to-end.

```sh
$ nix build .#cbind
$ ls result/lib/
liblibp2p_mix_rln.a  liblibp2p_mix_rln.so
$ ls result/include/
libp2p_mix_rln.h  nim_ffi_cbor.h  nim_ffi_prelude.h  tinycbor/
```

Depends on:
- `github:vacp2p/zerokit` as a flake input (supplies `librln.a`). Requires the
  post-2026-08 zerokit that carries [PR #435](https://github.com/vacp2p/zerokit/pull/435)
  — earlier revisions hit a crates.io 403 during their cargo-vendor step and a
  stale `cargoHash` from v2.0.0.
- Nim 2.2.10 (from `pkgs.nim-2_2`).

`nix/cbind.nix` also wraps `nim-nat-traversal` in a small builder derivation that
compiles its vendored miniupnp / libnatpmp C sources into the `.a` files nim-libp2p
links against — nix's `fetchgit` skips nat_traversal's `before install` hook, so this
happens in-derivation instead.

**Local `nimble buildffi`** ships with a `nimble.lock` extended from
`nim-libp2p/cbind/nimble.lock`, with `libp2p @ v2.1.4`, `libp2p_mix @ c387ca67`,
`mix_rln_spam_protection @ 135182b7`, and `nim-ffi` repinned to `b6c17dc` (the
master-reachable equivalent of `nim-libp2p/cbind`'s `b95e2b04…`, which lives on
unmerged branch `fix/cbor-non-canonical` and can't be fetched by nimble's
shallow-clone-of-master strategy).

On this machine, `nimble -l setup` fails building `testutils` with a stdlib/compiler
mismatch after nimble downloads and rebuilds its own copy of nim 2.2.10 from source
— likely a nimble bug. If you hit it: delete the `nimbledeps/pkgs2/nim-*` dir
after nimble installs it, and let subsequent `nimble develop` calls use system nim.
Or just use the nix path.

## Layout

```
nim-libp2p-mix-rln/
├── nim_libp2p_mix_rln.nimble     # package + `buildffi` + `genbindings_c`
├── libp2p_mix_rln.nim            # FFI entry — declareLibrary(), types, procs, genBindings()
├── libp2p_mix_rln/
│   └── config.nim                # `{.ffi.}` config schema (mirrors metadata.json)
├── nix/
│   ├── cbind.nix                 # hermetic build derivation
│   └── cbind-deps.nix            # 26 pinned deps, real sha256s
├── tools/
│   └── regen-cbind-deps.py       # regenerate cbind-deps.nix after bumping pins
├── flake.nix                     # outputs packages.<system>.cbind
├── Makefile                      # thin wrapper: `make buildffi` / `make genbindings`
├── config.nims
├── LICENSE-MIT
├── LICENSE-APACHEv2
└── README.md
```

## Build (local)

```sh
# 1. Build librln.a from vacp2p/zerokit (out of scope here).
export LIBRLN_PATH=/path/to/librln.a

# 2. Install nim deps into ./nimbledeps
nimble -l setup -y

# 3. Build the shared library and header.
make buildffi genbindings
# → build/liblibp2p_mix_rln.so
# → c_bindings/libp2p_mix_rln.h
```

## Build (nix, hermetic)

```sh
nix build .#cbind
# → result/lib/liblibp2p_mix_rln.{so,a}
# → result/include/libp2p_mix_rln.h + tinycbor/
```

This is what [logos-libp2p-mix-rln][logos-mod]'s flake consumes as its
`libp2p_mix_rln` external library input.

[libp2p]: https://github.com/vacp2p/nim-libp2p
[mix]: https://github.com/logos-co/nim-libp2p-mix
[mix-rln]: https://github.com/logos-co/mix-rln-spam-protection-plugin
[logos-mod]: https://github.com/logos-co/logos-libp2p-mix-rln
[nim-ffi]: https://github.com/logos-messaging/nim-ffi
[zerokit]: https://github.com/vacp2p/zerokit
