/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Std.Data.HashMap
import Jam.Backend

/-! # An in-memory Pigeonhole

A `Backend` for tests. A stream is named by the first 32 bytes of its read cap; an index is its
`Idx64` (8 bytes, little-endian) followed by the stream's key and padding. A box holds what was
first written to it: writing the same bytes again succeeds, as the replicas let a client rewrite a
box, and anything else fails. An empty write is a tombstone. A voucher's stream is named by the
voucher itself, and the daemon's cryptography is left out: the sealed reply is the reply, and
nothing is salted. -/

namespace Jam.Tests.Sim

open CryptWalker.GroupChat.Member

/-- What a box holds: bytes, or a tombstone. -/
abbrev Box := Option ByteArray

structure World where
  boxes : Std.HashMap (List UInt8 × Nat) Box := {}
  epoch : Option Nat := some 1
  /-- Writes to fail before one succeeds, to test retrying. -/
  failWrites : Nat := 0
  maxPlaintext : Nat := 1530
  /-- Each box written, in order: stream key, Idx64 and bytes. -/
  writes : Array (List UInt8 × Nat × ByteArray) := #[]

def indexOf (key : ByteArray) (n : Nat) : Index :=
  let le := (List.range 8).map fun i => (n / 256 ^ i % 256).toUInt8
  ⟨(le ++ key.data.toList ++ List.replicate (indexSize - 8 - key.size) 0).toArray⟩

def keyOfIndex (i : Index) : List UInt8 := (i.extract 8 40).data.toList

def capsOf (key : ByteArray) : ByteArray × ByteArray :=
  let readCap := key ++ indexOf key 0
  (ByteArray.mk (List.replicate 32 (0 : UInt8)).toArray ++ readCap, readCap)

def randomKey : IO ByteArray := IO.getRandomBytes 32

def backend (world : IO.Ref World) : Backend where
  newKeypair := do
    let (wc, rc) := capsOf (← randomKey)
    pure { writeCap := wc, readCap := rc, first := startOf rc }
  writeBox wc index plaintext := do
    let w ← world.get
    if w.failWrites > 0 then
      world.set { w with failWrites := w.failWrites - 1 }
      throw (IO.userError "sim: write failed")
    let key := (keyOf (readCapOf wc)).data.toList
    unless keyOfIndex index == key do throw (IO.userError "sim: index of another stream")
    let n := counter index
    let box : Box := if plaintext.size = 0 then none else some plaintext
    match w.boxes.get? (key, n) with
    | some old =>
      if old.map (·.data) != box.map (·.data) then
        throw (IO.userError "sim: box already exists")
    | none => pure ()
    world.set { w with boxes := w.boxes.insert (key, n) box,
                       writes := w.writes.push (key, n, plaintext) }
    pure (indexOf ⟨key.toArray⟩ (n + 1))
  readBox rc index := do
    let key := (keyOf rc).data.toList
    unless keyOfIndex index == key do throw (IO.userError "sim: index of another stream")
    let n := counter index
    let next := indexOf ⟨key.toArray⟩ (n + 1)
    match (← world.get).boxes.get? (key, n) with
    | none => pure .notFound
    | some none => pure (.tombstone next)
    | some (some b) => pure (.data b next)
  nextIndex index := pure (indexOf (index.extract 8 40) (counter index + 1))
  voucherMint wc name := do
    let voucher ← randomKey
    let (vwc, vrc) := capsOf voucher
    let payload := name.toUTF8.push 0 ++ readCapOf wc
    pure { voucher, payload, writeCap := vwc, readCap := vrc, secretKey := voucher }
  voucherDeriveStream voucher := pure (capsOf voucher)
  voucherInduct _ payload whoReply := do
    let some nul := payload.data.toList.idxOf? 0 | throw (IO.userError "sim: bad payload")
    let name := String.fromUTF8! (payload.extract 0 nul)
    pure { name, mutatedReadCap := payload.extract (nul + 1) payload.size, sealedReply := whoReply }
  voucherOpen _ sealed wc := pure { whoReply := sealed, mutatedWriteCap := wc }
  replicaEpoch := return (← world.get).epoch
  maxPlaintext := return (← world.get).maxPlaintext

end Jam.Tests.Sim
