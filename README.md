# nim-libp2p-mix-rln

C FFI facade composing [nim-libp2p][libp2p] + [nim-libp2p-mix][mix] +
[mix-rln-spam-protection-plugin][mix-rln]. Produces
`liblibp2p_mix_rln.{so,dylib,dll}` and `libp2p_mix_rln.h` for consumption by
[logos-libp2p-mix-rln][logos-mod]'s C++/Qt module.

Analogous to `vacp2p/nim-libp2p`'s `cbind` package, and modelled on its
build. Uses [nim-ffi][nim-ffi] for pragma-driven codegen of the C header.

## Status: second pass

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

## Known blockers to first build

### 1. `nimble -l setup`

Ships with a working `nimble.lock` — cloned from `nim-libp2p/cbind/nimble.lock`,
extended with `libp2p @ v2.1.4`, `libp2p_mix @ c387ca67`, `mix_rln_spam_protection @ 135182b7`,
and `nim-ffi` repinned to `b6c17dc` (the master-reachable equivalent of `nim-libp2p/cbind`'s
`b95e2b04…`, which lives on unmerged branch `fix/cbor-non-canonical` and can't be
fetched by nimble's shallow-clone-of-master strategy). SAT resolution succeeds.

On this machine, `nimble -l setup` **installs 5 deps then fails building `testutils`**
with `Error: system module needs: nimSubInt` — a `stdlib`-vs-`compiler` mismatch
after nimble builds its own nim 2.2.10 from source into `nimbledeps/pkgs2/nim-2.2.10-…/`.
Reproduces on nim 2.2.6.

Almost certainly a nimble bug rather than something in this repo's config —
`nim-libp2p/cbind` (source of the lockfile) presumably runs `nimble -l setup` in CI.
If your machine hits the same, workarounds:

- Delete the `nimbledeps/pkgs2/nim-*` dir after nimble installs it, and let subsequent
  `nimble develop` calls use system nim.
- Or `nimble install <url>` each dep individually with `--nolockfile` (bypasses the
  lockfile-driven install path).

### 2. `nix build .#cbind`

The zerokit input's build hits `Failed to fetch file from https://crates.io/api/v1/crates/colorchoice/1.0.5/download. Status code: 403` during `zerokit-3.0.0-vendor-staging`. Cause: nixpkgs' `fetch-cargo-vendor-util`
at the pin zerokit's flake uses (`23d72dabcb3b…`, "release-25.11") makes HTTP requests
without a `User-Agent`, and crates.io returns 403 for empty-UA requests. Verified
directly:

```
$ curl -so /dev/null -w '%{http_code}\n' https://crates.io/api/v1/crates/colorchoice/1.0.5/download
403
$ curl -so /dev/null -w '%{http_code}\n' -A 'any-ua' https://crates.io/api/v1/crates/colorchoice/1.0.5/download
302
```

Not transient. Workarounds:

- Add `nixpkgs` follows on the zerokit input pointing at a nixpkgs where the vendor
  fetcher sets a User-Agent (post-2026-03 revisions of `nixpkgs-unstable`).
- Or replace the `librln` input in `nix/cbind.nix` with a local-file derivation
  bootstrapped by running `cargo build --release --lib` inside a zerokit checkout
  and copying `target/release/librln.a` into `./vendor/`. (Trades reproducibility
  for a working build.)
- Or, upstream, patch zerokit's flake to override `fetch-cargo-vendor-util` with
  the User-Agent-setting version.

### 3. FFI macro round-trip (untested)

The `{.ffi.}` type shapes in `libp2p_mix_rln.nim` have not yet been round-tripped
through `nim-ffi`'s macro. Even once #1 or #2 is resolved, expect a first-pass round of
macro-rejection fixes (e.g. re-shaping any fields nim-ffi can't marshal).

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
