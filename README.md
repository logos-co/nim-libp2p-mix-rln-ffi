# nim-libp2p-mix-rln

C FFI facade composing [nim-libp2p][libp2p] + [nim-libp2p-mix][mix] +
[mix-rln-spam-protection-plugin][mix-rln]. Produces
`liblibp2p_mix_rln.{so,dylib,dll}` and `libp2p_mix_rln.h` for consumption by
[logos-libp2p-mix-rln][logos-mod]'s C++/Qt module.

Analogous to `vacp2p/nim-libp2p`'s `cbind` package, and modelled on its
build. Uses [nim-ffi][nim-ffi] for pragma-driven codegen of the C header.

## Status: first pass — does not yet build end-to-end

What's real:
- Package layout mirrors `nim-libp2p/cbind`.
- `nim_libp2p_mix_rln.nimble` pins the correct upstream SHAs. The
  historical libp2p diamond dep (mix pinning 2.0.0 / mix-rln pinning 2.1.4)
  is resolved by transitively depending on `mix_rln_spam_protection`, whose
  nimble already pins `nim-libp2p-mix` at SHA `c387ca67…` (which agrees on
  `libp2p == 2.1.4`).
- `libp2p_mix_rln.nim` has the full FFI API surface: `MixRlnConfig` +
  request/response types + event types + procs for lifecycle, RLN membership,
  mix send, SURB reply, mix-peer discovery, and cover-traffic knobs.
- `libp2pMixRlnCreate` / `Start` / `Stop` / `Destroy` / `GetNodeInfo` (Version,
  PeerId, Multiaddrs) have real bodies wired against `Switch`, `MixProtocol`,
  and `MixRlnSpamProtection`.

What's stubbed (returns `err("not implemented")`):
- `libp2pMixRlnSendMixMessage` / `SendMixSurbReply`
- `libp2pMixRlnRegisterRlnMembership` / `HasRlnMembership`
- `GetNodeInfo` fields `MixPublicKey`, `RlnMembershipIndex`

What's left to make it build:
1. **librln.a**. The RLN plugin links against `librln.a` from
   [vacp2p/zerokit][zerokit] (a Rust project). `LIBRLN_PATH` must point at
   that archive. Package it for nix so `flake.nix` can source it hermetically.
2. **`nix/cbind-deps.nix`**. Only the three deps carried over verbatim from
   `nim-libp2p/cbind` have real `sha256` values. The transitive closure
   (libp2p 2.1.4, libp2p_mix at the pinned SHA, mix-rln, secp256k1, chronos,
   chronicles, results, stew, nimcrypto, json_serialization, unittest2, …)
   needs entries with hashes from `nix-prefetch-git`.
3. **Verify the FFI compiles**. `nim-ffi`'s macro expansion has real
   constraints on `{.ffi.}` type shapes; the current source hasn't been run
   through the compiler yet. Any first-pass errors surface at
   `nimble buildffi`.
4. **Wire `MixRlnSpamProtection` into `MixProtocol.new(...)`**. Once the
   pinned `nim-libp2p-mix` SHA's constructor signature is confirmed, replace
   the plain `MixProtocol.new(nodeInfo, switch)` with the plugin-carrying
   form.
5. **Bridge `setPublishCallback` to a host-owned callback** so RLN
   membership/metadata traffic can leave the process via a Logos-messaging
   module registered from C.

## Layout

```
nim-libp2p-mix-rln/
├── nim_libp2p_mix_rln.nimble     # package + `buildffi` + `genbindings_c`
├── libp2p_mix_rln.nim            # FFI entry — declareLibrary(), types, procs, genBindings()
├── libp2p_mix_rln/
│   └── config.nim                # `{.ffi.}` config schema (mirrors metadata.json)
├── nix/
│   ├── cbind.nix                 # hermetic build derivation
│   └── cbind-deps.nix            # dep pins (some sha256s still PLACEHOLDER)
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
