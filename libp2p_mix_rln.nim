# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos

## C FFI facade composing nim-libp2p + nim-libp2p-mix + mix-rln-spam-protection-plugin.
##
## Modelled on vacp2p/nim-libp2p `cbind/libp2p.nim`: `{.ffi.}` types become
## CBOR-encoded request/response objects, `{.ffi.}` procs become C-exported
## async entry points, `genBindings()` at the bottom emits the C header.
##
## Consumed by [logos-libp2p-mix-rln](https://github.com/logos-co/logos-libp2p-mix-rln)
## via its `metadata.json` `nix.external_libraries` entry.
##
## STATUS: first pass. `libp2pMixRlnCreate/Start/Stop/GetNodeInfo/Destroy` are
## wired against real Switch/MixProtocol/MixRlnSpamProtection objects. The
## higher-level ops (`SendMixMessage`, `SendMixSurbReply`, `RegisterRlnMembership`,
## `ListMixPeers`, cover-traffic knobs) return `err("not implemented")` for now
## — they are the next iteration's work. See README.md.

import ffi

import std/[strutils, options, tables]
import chronos
import chronicles
import results

# nim-libp2p — dragged in transitively at v2.1.4 via mix_rln_spam_protection.
import libp2p/[switch, builders, multiaddress, peerid]
import libp2p/crypto/[crypto, secp]

# nim-libp2p-mix — Sphinx routing + mix protocol.
import libp2p_mix
import libp2p_mix/[mix_protocol, mix_node, curve25519]

# mix-rln-spam-protection-plugin — per-hop RLN proof gen/verify.
import mix_rln_spam_protection

# LibMixRln ------------------------------------------------------------------

type LibMixRln* = ref object
  ## Owned per FFI context. Every `{.ffi.}` proc receives one as its `lib`
  ## receiver and mutates through it. Lifetime is bounded by `libp2pMixRlnCreate`
  ## / `libp2pMixRlnDestroy`.
  rng: Rng
  switch: Switch
  mixProto: MixProtocol
  rlnPlugin: MixRlnSpamProtection
  mixNodeInfo: MixNodeInfo
  coverRateFraction: float64
  running: bool

declareLibrary("libp2p_mix_rln", LibMixRln)

# ----------------------------------------------------------------------------
# Config include — mirrors LIP LOGOS-MIXNET config surface as `{.ffi.}` types.
# ----------------------------------------------------------------------------

include "libp2p_mix_rln/config"

# Request / response types --------------------------------------------------

type NodeInfoField {.ffi.} = enum
  ## Field selector for `libp2pMixRlnGetNodeInfo`. Kept as a string enum so the
  ## wire vocabulary is stable across languages.
  Version = "version"
  PeerId = "peer_id"
  Multiaddrs = "multiaddrs"
  MixPublicKey = "mix_public_key"
  RlnMembershipIndex = "rln_membership_index"

type NodeInfoRequest {.ffi.} = object
  field: NodeInfoField

type NodeInfoResponse {.ffi.} = object
  value: string ## For Multiaddrs, a comma-joined list (parse on the host side).

type MixSendRequest {.ffi.} = object
  destPeerId: string     ## Multibase-encoded libp2p peer id of the exit destination.
  destMultiaddr: string  ## One routable multiaddr of the destination.
  proto: string          ## The libp2p protocol id the destination will accept the payload on.
  payload: seq[byte]
  expectReply: bool      ## If true, includes a single-use SURB for a reply.
  numSurbs: int64        ## Non-zero only when expectReply=true; LIP LOGOS-MIXNET expects 1.
  timeoutMs: int64

type MixSendResponse {.ffi.} = object
  surbId: string ## Empty when expectReply=false. Opaque to the host.

type MixSurbReplyRequest {.ffi.} = object
  surb: seq[byte]
  payload: seq[byte]

type CoverRateResponse {.ffi.} = object
  rate: float64

type SetCoverRateRequest {.ffi.} = object
  rate: float64

type MixPeerEntry {.ffi.} = object
  peerId: string
  multiaddrs: seq[string]
  mixPubKey: seq[byte]

type MixPeersResponse {.ffi.} = object
  peers: seq[MixPeerEntry]

type RlnMembershipStatus {.ffi.} = object
  registered: bool
  index: int64 ## -1 when not registered.

# Events emitted from the FFI back to the host ------------------------------

type IncomingMixMessageEvent {.ffi.} = object
  proto: string
  payload: seq[byte]
  surb: seq[byte]      ## Empty when the sender did not include one.

type RlnMembershipRegisteredEvent {.ffi.} = object
  index: int64
  root: seq[byte]

# ----------------------------------------------------------------------------
# Constructor / destructor
# ----------------------------------------------------------------------------

proc buildSwitch(cfg: MixRlnConfig, rng: Rng): Switch {.raises: [].} =
  ## Builds the libp2p Switch per LIP LOGOS-MIXNET: TCP + Noise + Mplex.
  ## QUIC support is left for the transport-selector follow-up.
  let skkey =
    if cfg.privKeyHex.len > 0:
      # TODO: hex-decode into SkPrivateKey. Falling through to a fresh key
      # until the decode helper is wired.
      SkKeyPair.random(rng).seckey
    else:
      SkKeyPair.random(rng).seckey
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  let addr0 = MultiAddress.init(cfg.addrs[0]).tryGet()
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(privKey)
    .withAddress(addr0)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

proc buildRlnPlugin(
    cfg: MixRlnConfig
): Future[Result[MixRlnSpamProtection, string]] {.async.} =
  ## Builds and initializes the RLN plugin. `setPublishCallback` is wired to a
  ## no-op here; a future revision will bridge it to a Logos-messaging module
  ## exposed to the host via a callback registered from C.
  var rlnCfg = defaultConfig()
  rlnCfg.keystorePath = cfg.rln.keystorePath
  rlnCfg.keystorePassword = cfg.rln.keystorePassword
  rlnCfg.treePath = cfg.rln.treePath
  rlnCfg.rlnResourcesPath = cfg.rln.rlnResourcesPath
  rlnCfg.epochDurationSeconds = float(cfg.rln.epochDurationSeconds)
  rlnCfg.maxEpochGap = cfg.rln.maxEpochGap
  rlnCfg.userMessageLimit = cfg.rln.userMessageLimit
  rlnCfg.membershipContentTopic = cfg.rln.membershipContentTopic
  rlnCfg.proofMetadataContentTopic = cfg.rln.proofMetadataContentTopic
  # rlnIdentifier: the C side passes hex; decode when the helper is wired.
  # For now, rely on the plugin's default.

  let plugin = MixRlnSpamProtection.new(rlnCfg).valueOr:
    return err("MixRlnSpamProtection.new failed: " & error)

  (await plugin.init()).isOkOr:
    return err("MixRlnSpamProtection.init failed: " & error)

  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      # TODO: bridge to logos-messaging via a host-registered callback.
      trace "rln publish (dropped — no host callback wired)",
        topic = topic, bytes = data.len
      return ok()
  )

  (await plugin.start()).isOkOr:
    return err("MixRlnSpamProtection.start failed: " & error)

  ok(plugin)

proc libp2pMixRlnCreate*(
    lib: LibMixRln, cfg: MixRlnConfig
): Future[Result[bool, string]] {.ffi.} =
  ## Builds Switch, MixProtocol, and MixRlnSpamProtection. Mounts the mix
  ## protocol on the switch. Does NOT start the switch — call
  ## `libp2pMixRlnStart` for that.
  let rng = newRng()

  # A future revision will accept the mix node info from config; the current
  # placeholder generates a fresh one on every create.
  let nodeInfo = MixNodeInfo.generateRandom(rng)

  let switch = buildSwitch(cfg, rng)

  let plugin = (await buildRlnPlugin(cfg)).valueOr:
    return err(error)

  let proto = MixProtocol.new(nodeInfo, switch)
    # TODO: pass `spamProtection = plugin, spamProtectionConfig = initSpamProtectionConfig()`
    # once the plugin-wired constructor is confirmed against the pinned
    # nim-libp2p-mix SHA (c387ca67…).

  switch.mount(proto)

  lib.rng = rng
  lib.switch = switch
  lib.mixProto = proto
  lib.rlnPlugin = plugin
  lib.mixNodeInfo = nodeInfo
  lib.coverRateFraction = cfg.mix.coverRateFraction
  lib.running = false

  ok(true)

proc libp2pMixRlnDestroy*(lib: LibMixRln): Future[void] {.ffiDtor.} =
  ## Stops the switch (idempotent) and drops references. The FFI runtime
  ## reclaims the LibMixRln object itself.
  if lib.running:
    try:
      await lib.switch.stop()
    except CatchableError as e:
      warn "switch.stop failed", err = e.msg
    lib.running = false
  # RLN plugin's own stop is called from libp2pMixRlnStop; nothing extra here.

# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------

proc libp2pMixRlnStart*(lib: LibMixRln): Future[Result[bool, string]] {.ffi.} =
  if lib.running: return ok(true)
  try:
    await lib.switch.start()
  except CatchableError as e:
    return err("switch.start failed: " & e.msg)
  lib.running = true
  ok(true)

proc libp2pMixRlnStop*(lib: LibMixRln): Future[Result[bool, string]] {.ffi.} =
  if not lib.running: return ok(true)
  try:
    await lib.switch.stop()
  except CatchableError as e:
    return err("switch.stop failed: " & e.msg)
  # TODO: await lib.rlnPlugin.stop() once its API is confirmed at the pinned SHA.
  lib.running = false
  ok(true)

# ----------------------------------------------------------------------------
# Node introspection
# ----------------------------------------------------------------------------

proc libp2pMixRlnGetNodeInfo*(
    lib: LibMixRln, req: NodeInfoRequest
): Future[Result[NodeInfoResponse, string]] {.ffi.} =
  case req.field
  of Version:
    ok(NodeInfoResponse(value: "0.1.0"))
  of PeerId:
    ok(NodeInfoResponse(value: $lib.switch.peerInfo.peerId))
  of Multiaddrs:
    var parts: seq[string]
    for a in lib.switch.peerInfo.addrs:
      parts.add($a)
    ok(NodeInfoResponse(value: parts.join(",")))
  of MixPublicKey:
    # MixNodeInfo carries the X25519 pubkey; expose it here once the accessor
    # name is confirmed against the pinned nim-libp2p-mix SHA.
    err("not implemented — MixPublicKey accessor pending")
  of RlnMembershipIndex:
    err("not implemented — RlnMembershipIndex accessor pending")

# ----------------------------------------------------------------------------
# RLN membership
# ----------------------------------------------------------------------------

proc libp2pMixRlnRegisterRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  # `discard await lib.rlnPlugin.registerSelf()` once the pinned SHA's
  # registerSelf return type is confirmed. Emitting the corresponding
  # RlnMembershipRegisteredEvent is the same follow-up.
  err("not implemented — RLN membership registration pending")

proc libp2pMixRlnHasRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  err("not implemented — RLN membership query pending")

# ----------------------------------------------------------------------------
# Mixnet send
# ----------------------------------------------------------------------------

proc libp2pMixRlnSendMixMessage*(
    lib: LibMixRln, req: MixSendRequest
): Future[Result[MixSendResponse, string]] {.ffi.} =
  # Sketch (to be verified against pinned SHA):
  #   let destAddr = MultiAddress.init(req.destMultiaddr).tryGet()
  #   let destPid  = PeerId.init(req.destPeerId).tryGet()
  #   let params   = MixParameters(expectReply: Opt.some(req.expectReply),
  #                                numSurbs: Opt.some(byte(req.numSurbs)))
  #   let conn = lib.mixProto.toConnection(
  #     MixDestination.init(destPid, destAddr), req.proto, params
  #   ).valueOr: return err("toConnection failed: " & error)
  #   await conn.writeLp(req.payload)
  #   await conn.close()
  err("not implemented — mix send pending")

proc libp2pMixRlnSendMixSurbReply*(
    lib: LibMixRln, req: MixSurbReplyRequest
): Future[Result[bool, string]] {.ffi.} =
  err("not implemented — SURB reply pending")

# ----------------------------------------------------------------------------
# Discovery / cover traffic
# ----------------------------------------------------------------------------

proc libp2pMixRlnListMixPeers*(
    lib: LibMixRln
): Future[Result[MixPeersResponse, string]] {.ffi.} =
  # Sourced from Logos Service Discovery + Extensible Peer Records once the
  # discovery module is mounted. Placeholder returns an empty list.
  ok(MixPeersResponse(peers: @[]))

proc libp2pMixRlnGetCoverTrafficRate*(
    lib: LibMixRln
): Future[Result[CoverRateResponse, string]] {.ffi.} =
  ok(CoverRateResponse(rate: lib.coverRateFraction))

proc libp2pMixRlnSetCoverTrafficRate*(
    lib: LibMixRln, req: SetCoverRateRequest
): Future[Result[bool, string]] {.ffi.} =
  if req.rate < 0.0 or req.rate > 1.0:
    return err("rate must be in [0.0, 1.0]")
  lib.coverRateFraction = req.rate
  # TODO: propagate to the cover-traffic scheduler once its handle is exposed.
  ok(true)

# ----------------------------------------------------------------------------
# Emit the C header.
# ----------------------------------------------------------------------------

genBindings()
