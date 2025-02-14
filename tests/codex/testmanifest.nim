import std/sequtils

import pkg/chronos
import pkg/questionable/results
import pkg/asynctest
import pkg/codex/chunker
import pkg/codex/blocktype as bt
import pkg/codex/manifest
import pkg/poseidon2

import pkg/codex/slots
import pkg/codex/merkletree

import ./helpers
import ./examples

checksuite "Manifest":
  let
    manifest = Manifest.new(
      treeCid = Cid.example,
      blockSize = 1.MiBs,
      datasetSize = 100.MiBs
    )

    protectedManifest = Manifest.new(
      manifest = manifest,
      treeCid = Cid.example,
      datasetSize = 200.MiBs,
      eck = 2,
      ecM = 2
    )

    leaves = [
      0.toF.Poseidon2Hash,
      1.toF.Poseidon2Hash,
      2.toF.Poseidon2Hash,
      3.toF.Poseidon2Hash]

    slotLeavesCids = leaves.toSlotCids().tryGet

    tree = Poseidon2Tree.init(leaves).tryGet
    slotsRootsCid = tree.root.tryGet.toSlotsRootsCid().tryGet

    verifiableManifest = Manifest.new(
      manifest = protectedManifest,
      verifyRoot = slotsRootsCid,
      slotRoots = slotLeavesCids
    ).tryGet()

  proc encodeDecode(manifest: Manifest): Manifest =
    let e = manifest.encode().tryGet()
    Manifest.decode(e).tryGet()

  test "Should encode/decode to/from base manifest":
    check:
      encodeDecode(manifest) == manifest

  test "Should encode/decode to/from protected manifest":
    check:
      encodeDecode(protectedManifest) == protectedManifest

  test "Should encode/decode to/from verifiable manifest":
    check:
      encodeDecode(verifiableManifest) == verifiableManifest
