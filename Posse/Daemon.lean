/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import ThinClient
import Posse.Backend

/-! # The client daemon

A `Backend` over the thin client: kpclientd does the Pigeonhole and voucher cryptography. Boxes
are read and written as katzenqt does (`network.py`): encrypt, then have the daemon resend until a
courier answers; a read reports a box not yet written at once rather than waiting for it. -/

namespace Posse.Daemon

open ThinClient Cborg

def fixed {n : Nat} (what : String) (b : ByteArray) : ClientM (FixedBytes n) :=
  match FixedBytes.ofBytes? b with
  | some f => pure f
  | none => throw (ThinClientError.decode s!"{what} is {b.size} bytes, not {n}")

/-- Run `x` on `client`, throwing what it throws. -/
def runIO {α : Type} (client : Client) (x : ClientM α) : IO α := do
  match ← (run client x).block with
  | .ok a => pure a
  | .error e => throw (IO.userError (toString e))

/-- The replica epoch most storage replicas are in: each publishes envelope keys up to the epoch
after its own (`acks.py`, `replica_epoch_of`). -/
def replicaEpochOf (doc : Document) : Option Nat :=
  let votes : List Nat := doc.storageReplicas.toList.filterMap fun r =>
    (r.envelopeKeys.entries.toList.map (·.1.toNat)).max?.map (· - 1)
  let counted := votes.eraseDups.map fun e => (e, votes.count e)
  (counted.foldl (fun best (e, n) => match best with
    | some (_, m) => if n > m then some (e, n) else best
    | none => some (e, n)) none).map (·.1)

def backend (client : Client) : Backend where
  newKeypair := runIO client do
    let kp ← newKeypair (← FixedBytes.random 32)
    pure { writeCap := kp.writeCap.bytes, readCap := kp.readCap.bytes,
           first := kp.firstMessageIndex.bytes }
  writeBox wc index plaintext := runIO client do
    let wc : WriteCap ← fixed "write cap" wc
    let index : MessageBoxIndex ← fixed "index" index
    let e ← encryptWrite plaintext wc index
    discard <| startResendingEncryptedMessage (.write wc) e.envelopeDescriptor
      e.messageCiphertext e.envelopeHash
    pure e.nextMessageBoxIndex.bytes
  readBox rc index := runIO client do
    let rc : ReadCap ← fixed "read cap" rc
    let index : MessageBoxIndex ← fixed "index" index
    let e ← encryptRead rc index
    try
      let r ← startResendingEncryptedMessage (.read rc index) e.envelopeDescriptor
        e.messageCiphertext e.envelopeHash { noRetryOnBoxIdNotFound := true }
      pure (.data r.plaintext e.nextMessageBoxIndex.bytes)
    catch
      | .replica .boxIdNotFound => pure .notFound
      | .replica .tombstone => pure (.tombstone e.nextMessageBoxIndex.bytes)
      | err => throw err
  nextIndex index := runIO client do
    let index : MessageBoxIndex ← fixed "index" index
    pure (← nextMessageBoxIndex index).bytes
  voucherMint wc name := runIO client do
    let m ← voucherMint wc name
    pure { voucher := m.voucher, payload := m.voucherPayload, writeCap := m.voucherWriteCap,
           readCap := m.voucherReadCap, secretKey := m.voucherSecretKey }
  voucherDeriveStream voucher := runIO client do
    let d ← voucherDeriveStream voucher
    pure (d.voucherWriteCap, d.voucherReadCap)
  voucherInduct voucher payload who := runIO client do
    let i ← voucherInduct voucher payload who
    pure { name := i.displayName, mutatedReadCap := i.mutatedMessageReadCap,
           sealedReply := i.sealedReply }
  voucherOpen sk sealed wc := runIO client do
    let o ← voucherOpen sk sealed wc
    pure { whoReply := o.whoReply, mutatedWriteCap := o.mutatedMessageWriteCap }
  replicaEpoch := runIO client do
    try pure (replicaEpochOf (← pkiDocument)) catch _ => pure none
  maxPlaintext := runIO client do
    pure (← pigeonholeGeometry).maxPlaintextPayloadLength

end Posse.Daemon
