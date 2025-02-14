## Nim-Codex
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

# This module implements serialization and deserialization of Manifest

import pkg/upraises

push: {.upraises: [].}

import std/tables
import std/sequtils

import pkg/libp2p
import pkg/questionable
import pkg/questionable/results
import pkg/chronicles
import pkg/chronos

import ./manifest
import ../errors
import ../blocktype

proc encode*(manifest: Manifest): ?!seq[byte] =
  ## Encode the manifest into a ``ManifestCodec``
  ## multicodec container (Dag-pb) for now
  ##

  ? manifest.verify()
  var pbNode = initProtoBuffer()

  # NOTE: The `Data` field in the the `dag-pb`
  # contains the following protobuf `Message`
  #
  # ```protobuf
  #   Message VerificationInfo {
  #     bytes verifyRoot = 1;             # Decimal encoded field-element
  #     repeated bytes slotRoots = 2;     # Decimal encoded field-elements
  #   }
  #   Message ErasureInfo {
  #     optional uint32 ecK = 1;                            # number of encoded blocks
  #     optional uint32 ecM = 2;                            # number of parity blocks
  #     optional bytes originalTreeCid = 3;                 # cid of the original dataset
  #     optional uint32 originalDatasetSize = 4;            # size of the original dataset
  #     optional VerificationInformation verification = 5;  # verification information
  #   }
  #
  #   Message Header {
  #     optional bytes treeCid = 1;       # cid (root) of the tree
  #     optional uint32 blockSize = 2;    # size of a single block
  #     optional uint64 datasetSize = 3;  # size of the dataset
  #     optional codec: MultiCodec = 4;   # Dataset codec
  #     optional hcodec: MultiCodec = 5   # Multihash codec
  #     optional version: CidVersion = 6; # Cid version
  #     optional ErasureInfo erasure = 7; # erasure coding info
  #   }
  # ```
  #
  # var treeRootVBuf = initVBuffer()
  var header = initProtoBuffer()
  header.write(1, manifest.treeCid.data.buffer)
  header.write(2, manifest.blockSize.uint32)
  header.write(3, manifest.datasetSize.uint32)
  header.write(4, manifest.codec.uint32)
  header.write(5, manifest.hcodec.uint32)
  header.write(6, manifest.version.uint32)
  if manifest.protected:
    var erasureInfo = initProtoBuffer()
    erasureInfo.write(1, manifest.ecK.uint32)
    erasureInfo.write(2, manifest.ecM.uint32)
    erasureInfo.write(3, manifest.originalTreeCid.data.buffer)
    erasureInfo.write(4, manifest.originalDatasetSize.uint32)

    if manifest.verifiable:
      var verificationInfo = initProtoBuffer()
      verificationInfo.write(1, manifest.verifyRoot.data.buffer)
      for slotRoot in manifest.slotRoots:
        verificationInfo.write(2, slotRoot.data.buffer)
      erasureInfo.write(5, verificationInfo)

    erasureInfo.finish()
    header.write(7, erasureInfo)

  pbNode.write(1, header) # set the treeCid as the data field
  pbNode.finish()

  return pbNode.buffer.success

proc decode*(_: type Manifest, data: openArray[byte]): ?!Manifest =
  ## Decode a manifest from a data blob
  ##

  var
    pbNode = initProtoBuffer(data)
    pbHeader: ProtoBuffer
    pbErasureInfo: ProtoBuffer
    pbVerificationInfo: ProtoBuffer
    treeCidBuf: seq[byte]
    originalTreeCid: seq[byte]
    datasetSize: uint32
    codec: uint32
    hcodec: uint32
    version: uint32
    blockSize: uint32
    originalDatasetSize: uint32
    ecK, ecM: uint32
    verifyRoot: seq[byte]
    slotRoots: seq[seq[byte]]

  # Decode `Header` message
  if pbNode.getField(1, pbHeader).isErr:
    return failure("Unable to decode `Header` from dag-pb manifest!")

  # Decode `Header` contents
  if pbHeader.getField(1, treeCidBuf).isErr:
    return failure("Unable to decode `treeCid` from manifest!")

  if pbHeader.getField(2, blockSize).isErr:
    return failure("Unable to decode `blockSize` from manifest!")

  if pbHeader.getField(3, datasetSize).isErr:
    return failure("Unable to decode `datasetSize` from manifest!")

  if pbHeader.getField(4, codec).isErr:
    return failure("Unable to decode `codec` from manifest!")

  if pbHeader.getField(5, hcodec).isErr:
    return failure("Unable to decode `hcodec` from manifest!")

  if pbHeader.getField(6, version).isErr:
    return failure("Unable to decode `version` from manifest!")

  if pbHeader.getField(7, pbErasureInfo).isErr:
    return failure("Unable to decode `erasureInfo` from manifest!")

  let protected = pbErasureInfo.buffer.len > 0
  var verifiable = false
  if protected:
    if pbErasureInfo.getField(1, ecK).isErr:
      return failure("Unable to decode `K` from manifest!")

    if pbErasureInfo.getField(2, ecM).isErr:
      return failure("Unable to decode `M` from manifest!")

    if pbErasureInfo.getField(3, originalTreeCid).isErr:
      return failure("Unable to decode `originalTreeCid` from manifest!")

    if pbErasureInfo.getField(4, originalDatasetSize).isErr:
      return failure("Unable to decode `originalDatasetSize` from manifest!")

    if pbErasureInfo.getField(5, pbVerificationInfo).isErr:
      return failure("Unable to decode `verificationInfo` from manifest!")

    verifiable = pbVerificationInfo.buffer.len > 0
    if verifiable:
      if pbVerificationInfo.getField(1, verifyRoot).isErr:
        return failure("Unable to decode `verifyRoot` from manifest!")

      if pbVerificationInfo.getRequiredRepeatedField(2, slotRoots).isErr:
        return failure("Unable to decode `slotRoots` from manifest!")

  let
    treeCid = ? Cid.init(treeCidBuf).mapFailure

  let
    self = if protected:
      Manifest.new(
        treeCid = treeCid,
        datasetSize = datasetSize.NBytes,
        blockSize = blockSize.NBytes,
        version = CidVersion(version),
        hcodec = hcodec.MultiCodec,
        codec = codec.MultiCodec,
        ecK = ecK.int,
        ecM = ecM.int,
        originalTreeCid = ? Cid.init(originalTreeCid).mapFailure,
        originalDatasetSize = originalDatasetSize.NBytes)
      else:
        Manifest.new(
          treeCid = treeCid,
          datasetSize = datasetSize.NBytes,
          blockSize = blockSize.NBytes,
          version = CidVersion(version),
          hcodec = hcodec.MultiCodec,
          codec = codec.MultiCodec)

  ? self.verify()

  if verifiable:
    let
      verifyRootCid = ? Cid.init(verifyRoot).mapFailure
      slotRootCids = slotRoots.mapIt(? Cid.init(it).mapFailure)

    return Manifest.new(
      manifest = self,
      verifyRoot = verifyRootCid,
      slotRoots = slotRootCids
    )

  self.success

func decode*(_: type Manifest, blk: Block): ?!Manifest =
  ## Decode a manifest using `decoder`
  ##

  if not ? blk.cid.isManifest:
    return failure "Cid not a manifest codec"

  Manifest.decode(blk.data)
