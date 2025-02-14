## Nim-Codex
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/tables
import std/sequtils

import pkg/chronicles
import pkg/chronos

import pkg/libp2p
import pkg/libp2p/utils/semaphore
import pkg/questionable
import pkg/questionable/results

import ../../blocktype as bt
import ../protobuf/blockexc as pb
import ../protobuf/payments

import ./networkpeer

export network, payments

logScope:
  topics = "codex blockexcnetwork"

const
  Codec* = "/codex/blockexc/1.0.0"
  MaxInflight* = 100

type
  WantListHandler* = proc(peer: PeerId, wantList: WantList): Future[void] {.gcsafe.}
  BlocksDeliveryHandler* = proc(peer: PeerId, blocks: seq[BlockDelivery]): Future[void] {.gcsafe.}
  BlockPresenceHandler* = proc(peer: PeerId, precense: seq[BlockPresence]): Future[void] {.gcsafe.}
  AccountHandler* = proc(peer: PeerId, account: Account): Future[void] {.gcsafe.}
  PaymentHandler* = proc(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.}
  WantListSender* = proc(
    id: PeerId,
    addresses: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false): Future[void] {.gcsafe.}

  BlockExcHandlers* = object
    onWantList*: WantListHandler
    onBlocksDelivery*: BlocksDeliveryHandler
    onPresence*: BlockPresenceHandler
    onAccount*: AccountHandler
    onPayment*: PaymentHandler

  BlocksDeliverySender* = proc(peer: PeerId, blocksDelivery: seq[BlockDelivery]): Future[void] {.gcsafe.}
  PresenceSender* = proc(peer: PeerId, presence: seq[BlockPresence]): Future[void] {.gcsafe.}
  AccountSender* = proc(peer: PeerId, account: Account): Future[void] {.gcsafe.}
  PaymentSender* = proc(peer: PeerId, payment: SignedState): Future[void] {.gcsafe.}

  BlockExcRequest* = object
    sendWantList*: WantListSender
    sendBlocksDelivery*: BlocksDeliverySender
    sendPresence*: PresenceSender
    sendAccount*: AccountSender
    sendPayment*: PaymentSender

  BlockExcNetwork* = ref object of LPProtocol
    peers*: Table[PeerId, NetworkPeer]
    switch*: Switch
    handlers*: BlockExcHandlers
    request*: BlockExcRequest
    getConn: ConnProvider
    inflightSema: AsyncSemaphore

proc peerId*(b: BlockExcNetwork): PeerId =
  ## Return peer id
  ##

  return b.switch.peerInfo.peerId

proc isSelf*(b: BlockExcNetwork, peer: PeerId): bool =
  ## Check if peer is self
  ##

  return b.peerId == peer

proc send*(b: BlockExcNetwork, id: PeerId, msg: pb.Message) {.async.} =
  ## Send message to peer
  ##

  b.peers.withValue(id, peer):
    try:
      await b.inflightSema.acquire()
      trace "Sending message to peer", peer = id
      await peer[].send(msg)
    except CatchableError as err:
      error "Error sending message", peer = id, msg = err.msg
    finally:
      b.inflightSema.release()
  do:
    trace "Unable to send, peer not found", peerId = id

proc handleWantList(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  list: WantList) {.async.} =
  ## Handle incoming want list
  ##

  if not b.handlers.onWantList.isNil:
    trace "Handling want list for peer", peer = peer.id, items = list.entries.len
    await b.handlers.onWantList(peer.id, list)

proc sendWantList*(
  b: BlockExcNetwork,
  id: PeerId,
  addresses: seq[BlockAddress],
  priority: int32 = 0,
  cancel: bool = false,
  wantType: WantType = WantType.WantHave,
  full: bool = false,
  sendDontHave: bool = false): Future[void] =
  ## Send a want message to peer
  ##

  trace "Sending want list to peer", peer = id, `type` = $wantType, items = addresses.len
  let msg = WantList(
    entries: addresses.mapIt(
      WantListEntry(
        address: it,
        priority: priority,
        cancel: cancel,
        wantType: wantType,
        sendDontHave: sendDontHave) ),
    full: full)

  b.send(id, Message(wantlist: msg))

proc handleBlocksDelivery(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  blocksDelivery: seq[BlockDelivery]) {.async.} =
  ## Handle incoming blocks
  ##

  if not b.handlers.onBlocksDelivery.isNil:
    trace "Handling blocks for peer", peer = peer.id, items = blocksDelivery.len
    await b.handlers.onBlocksDelivery(peer.id, blocksDelivery)


proc sendBlocksDelivery*(
  b: BlockExcNetwork,
  id: PeerId,
  blocksDelivery: seq[BlockDelivery]): Future[void] =
  ## Send blocks to remote
  ##

  b.send(id, pb.Message(payload: blocksDelivery))

proc handleBlockPresence(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  presence: seq[BlockPresence]) {.async.} =
  ## Handle block presence
  ##

  if not b.handlers.onPresence.isNil:
    trace "Handling block presence for peer", peer = peer.id, items = presence.len
    await b.handlers.onPresence(peer.id, presence)

proc sendBlockPresence*(
  b: BlockExcNetwork,
  id: PeerId,
  presence: seq[BlockPresence]): Future[void] =
  ## Send presence to remote
  ##

  b.send(id, Message(blockPresences: @presence))

proc handleAccount(
  network: BlockExcNetwork,
  peer: NetworkPeer,
  account: Account) {.async.} =
  ## Handle account info
  ##

  if not network.handlers.onAccount.isNil:
    await network.handlers.onAccount(peer.id, account)

proc sendAccount*(
  b: BlockExcNetwork,
  id: PeerId,
  account: Account): Future[void] =
  ## Send account info to remote
  ##

  b.send(id, Message(account: AccountMessage.init(account)))

proc sendPayment*(
  b: BlockExcNetwork,
  id: PeerId,
  payment: SignedState): Future[void] =
  ## Send payment to remote
  ##

  b.send(id, Message(payment: StateChannelUpdate.init(payment)))

proc handlePayment(
  network: BlockExcNetwork,
  peer: NetworkPeer,
  payment: SignedState) {.async.} =
  ## Handle payment
  ##

  if not network.handlers.onPayment.isNil:
    await network.handlers.onPayment(peer.id, payment)

proc rpcHandler(
  b: BlockExcNetwork,
  peer: NetworkPeer,
  msg: Message) {.async.} =
  ## handle rpc messages
  ##
  try:
    if msg.wantList.entries.len > 0:
      asyncSpawn b.handleWantList(peer, msg.wantList)

    if msg.payload.len > 0:
      asyncSpawn b.handleBlocksDelivery(peer, msg.payload)

    if msg.blockPresences.len > 0:
      asyncSpawn b.handleBlockPresence(peer, msg.blockPresences)

    if account =? Account.init(msg.account):
      asyncSpawn b.handleAccount(peer, account)

    if payment =? SignedState.init(msg.payment):
      asyncSpawn b.handlePayment(peer, payment)

  except CatchableError as exc:
    trace "Exception in blockexc rpc handler", exc = exc.msg

proc getOrCreatePeer(b: BlockExcNetwork, peer: PeerId): NetworkPeer =
  ## Creates or retrieves a BlockExcNetwork Peer
  ##

  if peer in b.peers:
    return b.peers.getOrDefault(peer, nil)

  var getConn: ConnProvider = proc(): Future[Connection] {.async, gcsafe, closure.} =
    try:
      return await b.switch.dial(peer, Codec)
    except CatchableError as exc:
      trace "Unable to connect to blockexc peer", exc = exc.msg

  if not isNil(b.getConn):
    getConn = b.getConn

  let rpcHandler = proc (p: NetworkPeer, msg: Message): Future[void] =
    b.rpcHandler(p, msg)

  # create new pubsub peer
  let blockExcPeer = NetworkPeer.new(peer, getConn, rpcHandler)
  debug "Created new blockexc peer", peer

  b.peers[peer] = blockExcPeer

  return blockExcPeer

proc setupPeer*(b: BlockExcNetwork, peer: PeerId) =
  ## Perform initial setup, such as want
  ## list exchange
  ##

  discard b.getOrCreatePeer(peer)

proc dialPeer*(b: BlockExcNetwork, peer: PeerRecord) {.async.} =
  ## Dial a peer
  ##

  if b.isSelf(peer.peerId):
    trace "Skipping dialing self", peer = peer.peerId
    return

  await b.switch.connect(peer.peerId, peer.addresses.mapIt(it.address))

proc dropPeer*(b: BlockExcNetwork, peer: PeerId) =
  ## Cleanup disconnected peer
  ##

  b.peers.del(peer)

method init*(b: BlockExcNetwork) =
  ## Perform protocol initialization
  ##

  proc peerEventHandler(peerId: PeerId, event: PeerEvent) {.async.} =
    if event.kind == PeerEventKind.Joined:
      b.setupPeer(peerId)
    else:
      b.dropPeer(peerId)

  b.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Joined)
  b.switch.addPeerEventHandler(peerEventHandler, PeerEventKind.Left)

  proc handle(conn: Connection, proto: string) {.async, gcsafe, closure.} =
    let peerId = conn.peerId
    let blockexcPeer = b.getOrCreatePeer(peerId)
    await blockexcPeer.readLoop(conn)  # attach read loop

  b.handler = handle
  b.codec = Codec

proc new*(
  T: type BlockExcNetwork,
  switch: Switch,
  connProvider: ConnProvider = nil,
  maxInflight = MaxInflight): BlockExcNetwork =
  ## Create a new BlockExcNetwork instance
  ##

  let
    self = BlockExcNetwork(
      switch: switch,
      getConn: connProvider,
      inflightSema: newAsyncSemaphore(maxInflight))

  proc sendWantList(
    id: PeerId,
    cids: seq[BlockAddress],
    priority: int32 = 0,
    cancel: bool = false,
    wantType: WantType = WantType.WantHave,
    full: bool = false,
    sendDontHave: bool = false): Future[void] {.gcsafe.} =
    self.sendWantList(
      id, cids, priority, cancel,
      wantType, full, sendDontHave)

  proc sendBlocksDelivery(id: PeerId, blocksDelivery: seq[BlockDelivery]): Future[void] {.gcsafe.} =
    self.sendBlocksDelivery(id, blocksDelivery)

  proc sendPresence(id: PeerId, presence: seq[BlockPresence]): Future[void] {.gcsafe.} =
    self.sendBlockPresence(id, presence)

  proc sendAccount(id: PeerId, account: Account): Future[void] {.gcsafe.} =
    self.sendAccount(id, account)

  proc sendPayment(id: PeerId, payment: SignedState): Future[void] {.gcsafe.} =
    self.sendPayment(id, payment)

  self.request = BlockExcRequest(
    sendWantList: sendWantList,
    sendBlocksDelivery: sendBlocksDelivery,
    sendPresence: sendPresence,
    sendAccount: sendAccount,
    sendPayment: sendPayment)

  self.init()
  return self
