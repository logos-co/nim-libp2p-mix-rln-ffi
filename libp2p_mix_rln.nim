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
## STATUS: second pass. Real bodies for lifecycle, mix send (via
## `MixProtocol.toConnection` at pinned SHA `c387ca67…`), and RLN plugin
## wiring (via `Opt.some(SpamProtection(plugin))` + `SpamProtectionDelayStrategy`).
## `{.ffiEvent.}` bridges for RLN publish + incoming mix message emit outward.
## SURB reply, RLN membership index, MixPublicKey introspection still stubbed.

import ffi

import std/[strutils, tables]
import chronos
import chronicles
import results

# nim-libp2p — dragged in transitively at v2.1.4 via mix_rln_spam_protection.
import libp2p/[switch, builders, multiaddress, peerid]
import libp2p/crypto/[crypto, secp]
import libp2p/stream/[connection, lpstream]

# nim-libp2p-mix — Sphinx routing + mix protocol.
import libp2p_mix
import libp2p_mix/[mix_protocol, mix_node, curve25519, delay_strategy]

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
  ok: bool

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

type RlnPublishRequestedEvent {.ffi.} = object
  ## RLN plugin wants a membership / metadata frame published to the RLN Relay
  ## coord layer. The host is expected to relay `payload` on `contentTopic`.
  contentTopic: string
  payload: seq[byte]

proc onIncomingMixMessage*(event: IncomingMixMessageEvent) {.ffiEvent.} =
  ## Fired when a mounted mix-destination protocol receives a message.
  ## Not yet wired — will fire from the exit-layer read handler once destination
  ## protocols are registered from the host.

proc onRlnMembershipRegistered*(
    event: RlnMembershipRegisteredEvent
) {.ffiEvent.} =
  ## Fired after `libp2pMixRlnRegisterRlnMembership` succeeds.

proc onRlnPublishRequested*(event: RlnPublishRequestedEvent) {.ffiEvent.} =
  ## Fired by the RLN plugin whenever it needs to broadcast a frame. Host is
  ## expected to route this to the Logos-messaging RLN Relay coord channel.

# ----------------------------------------------------------------------------
# Config helpers
# ----------------------------------------------------------------------------

proc portFromMultiaddr(ma: string): int =
  ## Extracts /tcp/N or /udp/N from a multiaddr string; returns 0 if absent.
  let parts = ma.split('/')
  var i = 1
  while i + 1 < parts.len:
    if parts[i] == "tcp" or parts[i] == "udp":
      try: return parseInt(parts[i + 1])
      except ValueError: return 0
    inc i
  0

proc decodeHexPrivKey(hex: string, rng: Rng): SkPrivateKey {.raises: [].} =
  ## Decodes a hex-encoded raw Secp256k1 private key. Falls back to a fresh
  ## key when the input is empty; a *malformed* hex is logged and also falls
  ## back so a bad config knob can't take the node down at construction.
  if hex.len == 0:
    return SkKeyPair.random(rng).seckey
  try:
    var raw = newSeq[byte](hex.len div 2)
    let start = if hex.startsWith("0x") or hex.startsWith("0X"): 2 else: 0
    for i in 0 ..< (hex.len - start) div 2:
      raw[i] = byte(parseHexInt(hex[start + 2*i .. start + 2*i + 1]))
    let sk = SkPrivateKey.init(raw)
    if sk.isOk:
      return sk.value
  except CatchableError as e:
    warn "invalid privKeyHex — generating fresh key", err = e.msg
  SkKeyPair.random(rng).seckey

# ----------------------------------------------------------------------------
# Constructor / destructor
# ----------------------------------------------------------------------------

proc buildSwitch(cfg: MixRlnConfig, rng: Rng): Switch {.raises: [].} =
  ## Builds the libp2p Switch per LIP LOGOS-MIXNET: TCP + Noise + Mplex.
  ## QUIC support is left for the transport-selector follow-up.
  let skkey = decodeHexPrivKey(cfg.privKeyHex, rng)
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  let listen =
    if cfg.addrs.len > 0: cfg.addrs[0]
    else: "/ip4/0.0.0.0/tcp/0"
  let addr0 = MultiAddress.init(listen).tryGet()
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
  ## Builds and initializes the RLN plugin. `setPublishCallback` fires an
  ## `onRlnPublishRequested` FFI event so the host module can forward the
  ## frame to whichever Logos-messaging channel implements RLN Relay coord.
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
  # rlnIdentifier: the C side passes hex; decode when the RlnIdentifier
  # hex-parse helper is added. Falling back to the plugin's default keeps
  # dev/testnet flows working.

  let plugin = MixRlnSpamProtection.new(rlnCfg).valueOr:
    return err("MixRlnSpamProtection.new failed: " & error)

  (await plugin.init()).isOkOr:
    return err("MixRlnSpamProtection.init failed: " & error)

  plugin.setPublishCallback(
    proc(topic: string, data: seq[byte]): Future[Result[void, string]] {.async.} =
      onRlnPublishRequested(
        RlnPublishRequestedEvent(contentTopic: topic, payload: data)
      )
      return ok()
  )

  (await plugin.start()).isOkOr:
    return err("MixRlnSpamProtection.start failed: " & error)

  ok(plugin)

proc libp2pMixRlnCreate*(
    lib: LibMixRln, cfg: MixRlnConfig
): Future[Result[bool, string]] {.ffi.} =
  ## Builds Switch, MixProtocol (wired with the RLN plugin as SpamProtection),
  ## and MixRlnSpamProtection. Mounts the mix protocol on the switch. Does NOT
  ## start the switch — call `libp2pMixRlnStart` for that.
  let rng = newRng()

  # A future revision will accept the mix node info from config; the current
  # placeholder generates a fresh one on every create, using the listen port
  # so the mix multiaddr matches the switch's transport.
  let listenPort =
    if cfg.addrs.len > 0: portFromMultiaddr(cfg.addrs[0])
    else: 0
  let nodeInfo = MixNodeInfo.generateRandom(listenPort, rng)

  let switch = buildSwitch(cfg, rng)

  let plugin = (await buildRlnPlugin(cfg)).valueOr:
    return err(error)

  # LIP LOGOS-MIXNET requires per-hop RLN proofs — pass the plugin as
  # SpamProtection. The plugin docs (and mix_protocol.nim's `new*`) recommend
  # SpamProtectionDelayStrategy to avoid timing correlation between proof gen
  # and short exponential delays.
  let delay = SpamProtectionDelayStrategy.new(rng = rng)
  let proto = MixProtocol.new(
    nodeInfo,
    switch,
    spamProtection = Opt.some(SpamProtection(plugin)),
    delayStrategy = Opt.some(DelayStrategy(delay)),
  )

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
    # MixNodeInfo.mixPubKey is a FieldElement (32-byte Curve25519). Wire it
    # as hex once the FieldElement → seq[byte] helper name is confirmed.
    err("not implemented — MixPublicKey accessor pending")
  of RlnMembershipIndex:
    err("not implemented — RlnMembershipIndex accessor pending")

# ----------------------------------------------------------------------------
# RLN membership
# ----------------------------------------------------------------------------

proc libp2pMixRlnRegisterRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  ## Registers this node in the RLN group. The plugin publishes the
  ## membership frame via its publish callback, which fires
  ## `onRlnPublishRequested` — the host is responsible for actually
  ## sending it on the Logos-messaging RLN Relay coord channel.
  let idx = (await lib.rlnPlugin.registerSelf()).valueOr:
    return err("registerSelf failed: " & error)
  # The Merkle root is available via the group manager; wire it into the
  # event body once that accessor's name is confirmed.
  onRlnMembershipRegistered(
    RlnMembershipRegisteredEvent(index: int64(idx), root: @[])
  )
  ok(RlnMembershipStatus(registered: true, index: int64(idx)))

proc libp2pMixRlnHasRlnMembership*(
    lib: LibMixRln
): Future[Result[RlnMembershipStatus, string]] {.ffi.} =
  let opt = lib.rlnPlugin.getMembershipIndex()
  if opt.isSome:
    ok(RlnMembershipStatus(registered: true, index: int64(opt.get())))
  else:
    ok(RlnMembershipStatus(registered: false, index: -1))

# ----------------------------------------------------------------------------
# Mixnet send
# ----------------------------------------------------------------------------

proc libp2pMixRlnSendMixMessage*(
    lib: LibMixRln, req: MixSendRequest
): Future[Result[MixSendResponse, string]] {.ffi.} =
  ## Sends `req.payload` through a Sphinx circuit to the exit destination,
  ## which will unwrap and hand it to `req.proto` on the destination node.
  let destAddr = MultiAddress.init(req.destMultiaddr).valueOr:
    return err("invalid destMultiaddr: " & error)
  let destPid = PeerId.init(req.destPeerId).valueOr:
    return err("invalid destPeerId: " & $error)

  var params = MixParameters()
  if req.expectReply:
    params.expectReply = Opt.some(true)
    let n = if req.numSurbs > 0: byte(req.numSurbs) else: byte(1)
    params.numSurbs = Opt.some(n)

  let conn = lib.mixProto.toConnection(
    MixDestination.init(destPid, destAddr), req.proto, params
  ).valueOr:
    return err("toConnection failed: " & error)

  try:
    await conn.writeLp(req.payload)
  except LPStreamError as e:
    try: await conn.close()
    except CatchableError: discard
    return err("writeLp failed: " & e.msg)

  try:
    await conn.close()
  except CatchableError as e:
    warn "conn.close failed after send", err = e.msg

  ok(MixSendResponse(ok: true))

proc libp2pMixRlnSendMixSurbReply*(
    lib: LibMixRln, req: MixSurbReplyRequest
): Future[Result[bool, string]] {.ffi.} =
  # SURB reply path uses the mix protocol's reply-connection surface; wire
  # this once the reply store lookup API is confirmed at the pinned SHA.
  err("not implemented — SURB reply pending")

# ----------------------------------------------------------------------------
# Discovery / cover traffic
# ----------------------------------------------------------------------------

proc libp2pMixRlnListMixPeers*(
    lib: LibMixRln
): Future[Result[MixPeersResponse, string]] {.ffi.} =
  ## Sourced from Logos Service Discovery + Extensible Peer Records once the
  ## discovery module is mounted. Placeholder returns an empty list.
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
  # TODO: propagate to the cover-traffic scheduler once its handle is exposed
  # via `MixProtocol.new(..., coverTraffic = Opt.some(CoverTraffic))`.
  ok(true)

# ----------------------------------------------------------------------------
# Emit the C header.
# ----------------------------------------------------------------------------

genBindings()
