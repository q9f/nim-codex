## Nim-Codex
## Copyright (c) 2023 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/sequtils

import pkg/poseidon2
import pkg/constantine/math/io/io_fields
import pkg/constantine/platforms/abstractions
import pkg/questionable/results

import ../utils
import ../rng

import ./merkletree

export merkletree, poseidon2

const
  KeyNoneF              = F.fromhex("0x0")
  KeyBottomLayerF       = F.fromhex("0x1")
  KeyOddF               = F.fromhex("0x2")
  KeyOddAndBottomLayerF = F.fromhex("0x3")

  Poseidon2Zero* = zero

type
  Poseidon2Hash* = F

  PoseidonKeysEnum* = enum  # can't use non-ordinals as enum values
    KeyNone
    KeyBottomLayer
    KeyOdd
    KeyOddAndBottomLayer

  Poseidon2Tree* = MerkleTree[Poseidon2Hash, PoseidonKeysEnum]
  Poseidon2Proof* = MerkleProof[Poseidon2Hash, PoseidonKeysEnum]

func toArray32*(bytes: openArray[byte]): array[32, byte] =
  result[0..<bytes.len] = bytes[0..<bytes.len]

converter toKey*(key: PoseidonKeysEnum): Poseidon2Hash =
  case key:
  of KeyNone: KeyNoneF
  of KeyBottomLayer: KeyBottomLayerF
  of KeyOdd: KeyOddF
  of KeyOddAndBottomLayer: KeyOddAndBottomLayerF

func init*(
  _: type Poseidon2Tree,
  leaves: openArray[Poseidon2Hash]): ?!Poseidon2Tree =

  if leaves.len == 0:
    return failure "Empty leaves"

  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  var
    self = Poseidon2Tree(compress: compressor, zero: Poseidon2Zero)

  self.layers = ? merkleTreeWorker(self, leaves, isBottomLayer = true)
  success self

func init*(
  _: type Poseidon2Tree,
  leaves: openArray[array[31, byte]]): ?!Poseidon2Tree =
  Poseidon2Tree.init(
    leaves.mapIt( Poseidon2Hash.fromBytes(it) ))

proc fromNodes*(
  _: type Poseidon2Tree,
  nodes: openArray[Poseidon2Hash],
  nleaves: int): ?!Poseidon2Tree =

  if nodes.len == 0:
    return failure "Empty nodes"

  let
    compressor = proc(
      x, y: Poseidon2Hash,
      key: PoseidonKeysEnum): ?!Poseidon2Hash {.noSideEffect.} =
      success compress( x, y, key.toKey )

  var
    self = Poseidon2Tree(compress: compressor, zero: zero)
    layer = nleaves
    pos = 0

  while pos < nodes.len:
    self.layers.add( nodes[pos..<(pos + layer)] )
    pos += layer
    layer = divUp(layer, 2)

  let
    index = Rng.instance.rand(nleaves - 1)
    proof = ? self.getProof(index)

  ? proof.verify(self.leaves[index], ? self.root) # sanity check

  success self
