# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos
#
# Full-stack integration test: mix routing with per-hop RLN proofs.
#
# Adds `MixRlnSpamProtection` to every mix node in `test_mix_routing.nim`.
# Because each plugin's `OffchainGroupManager` maintains its own local Merkle
# tree of memberships and sync happens via a coordination channel (RLN Relay
# in production), we wire an in-process publish bus here: each plugin's
# `setPublishCallback` publishes into a shared queue; a dispatcher routes
# frames back to every OTHER plugin's `handleMembershipUpdate` /
# `handleProofMetadata`. After `registerSelf()` completes on every plugin,
# each plugin's tree contains every node's credentials — the precondition
# for per-hop proof verification to succeed along a Sphinx path.
#
# What this proves that test_mix_routing.nim doesn't:
#   - MixRlnSpamProtection composes correctly with MixProtocol (spamProtection
#     arg wired through Opt.some(SpamProtection(plugin))).
#   - Real zkSNARK proof generation runs at every hop.
#   - Verification succeeds along the whole path (every hop finds the sender's
#     commitment in its own Merkle tree).
#   - The publish-callback surface is enough coordination glue for a working
#     multi-node group — the same seam our FFI facade exposes via
#     `onRlnPublishRequested` for the host module to bridge.

{.used.}

import chronicles, chronos, results
import std/[sequtils]
import libp2p/[
    protocols/ping, peerid, multiaddress, switch, builders, crypto/crypto,
    crypto/secp,
]
import libp2p_mix
import libp2p_mix/mix_protocol
import libp2p_mix/curve25519
import libp2p_mix/delay_strategy
import libp2p_mix/spam_protection as libp2p_spam
import mix_rln_spam_protection

# Path length 3 needs at least 3 candidates besides the sender and destination
# — 5 mix nodes is comfortable. Also keeps the total on-boot delay reasonable
# (each registerSelf runs a zkSNARK setup step).
const NumMixNodes = 5

proc createSwitch(
    multiAddr: MultiAddress,
    rng: Rng,
    libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey),
): Switch =
  let skkey = libp2pPrivKey.valueOr(SkKeyPair.random(rng).seckey)
  let privKey = PrivateKey(scheme: Secp256k1, skkey: skkey)
  SwitchBuilder
    .new()
    .withRng(rng)
    .withPrivateKey(privKey)
    .withAddress(multiAddr)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

# ---------------------------------------------------------------------------
# In-process publish bus
# ---------------------------------------------------------------------------
#
# Emulates the RLN Relay coordination channel. `plugins` is the full set of
# MixRlnSpamProtection instances in the test; the returned callback fans an
# outgoing publish out to every OTHER plugin's decoder. `sender` is used to
# skip the originator (its own tree is already updated as a side effect of
# registerSelf).

type PublishBus = ref object
  plugins: seq[MixRlnSpamProtection]

proc newPublishBus(): PublishBus =
  PublishBus(plugins: @[])

proc makeCallback(bus: PublishBus, sender: MixRlnSpamProtection): PublishCallback =
  return proc(
      topic: string, data: seq[byte]
  ): Future[Result[void, string]] {.async.} =
    for p in bus.plugins:
      if p == sender:
        continue
      if topic == p.getMembershipContentTopic():
        let r = await p.handleMembershipUpdate(data)
        if r.isErr:
          warn "handleMembershipUpdate failed on peer", err = r.error
      elif topic == p.getProofMetadataContentTopic():
        let r = p.handleProofMetadata(data)
        if r.isErr:
          warn "handleProofMetadata failed on peer", err = r.error
    return ok()

# ---------------------------------------------------------------------------
# The test
# ---------------------------------------------------------------------------

proc mixPingWithRln() {.async: (raises: [Exception]).} =
  let rng = newRng()
  let mixNodeInfos = MixNodeInfo.generateRandomMany(NumMixNodes, rng)

  # Build every plugin first so the bus can hold references to all of them
  # before any registerSelf() fires (the very first registerSelf publishes a
  # membership frame that needs to reach the other plugins).
  let bus = newPublishBus()
  var plugins: seq[MixRlnSpamProtection] = @[]
  for i in 0 ..< NumMixNodes:
    var rlnCfg = defaultConfig()
    # Stateless zerokit build: no resources path needed. epochDurationSeconds
    # left at plugin default (10.0).
    let plugin = MixRlnSpamProtection.new(rlnCfg).valueOr:
      raise newException(Exception, "MixRlnSpamProtection.new failed: " & error)
    (await plugin.init()).isOkOr:
      raise newException(Exception, "plugin.init failed: " & error)
    plugins.add(plugin)
    bus.plugins.add(plugin)

  # Now that all plugins exist, register the bus callbacks and start each.
  for p in plugins:
    p.setPublishCallback(makeCallback(bus, p))
    (await p.start()).isOkOr:
      raise newException(Exception, "plugin.start failed: " & error)

  info "Registering RLN memberships across all mix nodes"
  for p in plugins:
    discard (await p.registerSelf()).valueOr:
      raise newException(Exception, "registerSelf failed: " & error)

  # Give the async publish fan-out a beat to drain into every peer's tree.
  await sleepAsync(200.milliseconds)

  var switches: seq[Switch] = @[]
  var mixProtos: seq[MixProtocol] = @[]

  for i, nodeInfo in mixNodeInfos:
    var switch =
      createSwitch(nodeInfo.multiAddr, rng, Opt.some(nodeInfo.libp2pPrivKey))
    # SpamProtectionDelayStrategy is what the plugin docs recommend when
    # spamProtection is wired — avoids timing correlation between the
    # constant per-proof cost and short exponential delays.
    let delay = SpamProtectionDelayStrategy.new(rng = rng)
    let proto = MixProtocol.new(
      nodeInfo,
      switch,
      spamProtection = Opt.some(libp2p_spam.SpamProtection(plugins[i])),
      delayStrategy = Opt.some(DelayStrategy(delay)),
    )
    proto.nodePool.add(mixNodeInfos.includeAllExcept(nodeInfo))
    proto.registerDestReadBehavior(PingCodec, readExactly(32))
    switch.mount(proto)
    switches.add(switch)
    mixProtos.add(proto)

  defer:
    await switches.mapIt(it.stop()).allFutures()
    for p in plugins:
      try:
        await p.stop()
      except CatchableError as e:
        warn "plugin.stop failed", err = e.msg

  let destNode =
    createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), rng)
  defer:
    await destNode.stop()
  let pingProto = Ping.new(rng = rng)
  destNode.mount(pingProto)

  await switches.mapIt(it.start()).allFutures()
  await destNode.start()

  let senderIndex = 0
  info "Sending ping through mix network (per-hop RLN proofs enabled)",
    sender = switches[senderIndex].peerInfo.peerId,
    destination = destNode.peerInfo.peerId

  let conn = mixProtos[senderIndex]
    .toConnection(
      MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
      PingCodec,
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
    )
    .expect("could not build MixEntryConnection")

  let rtt = await pingProto.ping(conn)
  await conn.close()
  info "Ping response received through mix network with RLN", rtt = rtt

when isMainModule:
  waitFor(mixPingWithRln())
