# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Logos
#
# Runtime end-to-end validation for the composition our FFI facade wraps:
# nim-libp2p + nim-libp2p-mix. This test doesn't go through the FFI (that's
# validated separately by the C smoke test). It exercises the same
# `MixProtocol` / `Switch` composition our `libp2pMixRlnCreate` builds, then
# sends a real libp2p Ping through an anonymizing Sphinx circuit and verifies
# the round-trip.
#
# Adapted from vacp2p/nim-libp2p-mix's `examples/mix_ping.nim`.
#
# NOTE: RLN cross-registration between nodes is out of scope here. The mix-rln
# plugin's OffchainGroupManager relies on a coordination channel (RLN Relay
# content-topic) to sync memberships; wiring that in-process across N nodes is
# a follow-up. This test proves the *base* composition works — Sphinx routing,
# LIONESS payload encryption, per-hop delays, path selection.

{.used.}

import chronicles, chronos, results
import std/[strformat, sequtils]
import libp2p/[
    protocols/ping, peerid, multiaddress, switch, builders, crypto/crypto,
    crypto/secp,
]
import libp2p_mix
import libp2p_mix/mix_protocol
import libp2p_mix/curve25519

# Enough mix nodes for a comfortable path-length-3 Sphinx circuit plus room
# for random path selection.
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

proc mixPingRoundTrip() {.async: (raises: [Exception]).} =
  let rng = newRng()
  let mixNodeInfos = MixNodeInfo.generateRandomMany(NumMixNodes, rng)
  var switches: seq[Switch] = @[]
  var mixProtos: seq[MixProtocol] = @[]

  for nodeInfo in mixNodeInfos:
    var switch =
      createSwitch(nodeInfo.multiAddr, rng, Opt.some(nodeInfo.libp2pPrivKey))
    let proto = MixProtocol.new(nodeInfo, switch)
    proto.nodePool.add(mixNodeInfos.includeAllExcept(nodeInfo))
    # Ping replies are exactly 32 bytes with no length prefix.
    proto.registerDestReadBehavior(PingCodec, readExactly(32))
    switch.mount(proto)
    switches.add(switch)
    mixProtos.add(proto)

  defer:
    await switches.mapIt(it.stop()).allFutures()

  # Destination node — outside the mix network — hosts the ping responder.
  let destNode =
    createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(), rng)
  defer:
    await destNode.stop()

  let pingProto = Ping.new(rng = rng)
  destNode.mount(pingProto)

  await switches.mapIt(it.start()).allFutures()
  await destNode.start()

  let senderIndex = 0
  info "Sending ping through mix network",
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
  info "Ping response received through mix network", rtt = rtt

when isMainModule:
  waitFor(mixPingRoundTrip())
