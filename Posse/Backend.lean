/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import CryptWalker.GroupChat.Member.Wire

/-! # What posse asks of the network

Everything posse does on the network goes through a `Backend`: the client daemon over the thin
client, or `Sim`, an in-memory Pigeonhole for tests. Caps and indexes are opaque bytes: a write
cap is 168 bytes, a read cap 136 (the write cap's last 136), an index 104. -/

namespace Posse

open CryptWalker.GroupChat.Member

/-- What reading a box found. -/
inductive ReadOutcome
  | data (plaintext : ByteArray) (next : Index)
  | notFound
  | tombstone (next : Index)
  deriving Inhabited

structure Keypair where
  writeCap : ByteArray
  readCap : ByteArray
  first : Index

structure Minted where
  voucher : ByteArray
  payload : ByteArray
  writeCap : ByteArray
  readCap : ByteArray
  secretKey : ByteArray

structure Inducted where
  name : String
  mutatedReadCap : ByteArray
  sealedReply : ByteArray

structure Opened where
  whoReply : ByteArray
  mutatedWriteCap : ByteArray

/-- Each call throws on failure; a caller that must succeed retries. -/
structure Backend where
  newKeypair : IO Keypair
  /-- Write `plaintext`, empty for a tombstone, to the box at `index`; the index after it. -/
  writeBox : (writeCap : ByteArray) → (index : Index) → (plaintext : ByteArray) → IO Index
  readBox : (readCap : ByteArray) → (index : Index) → IO ReadOutcome
  nextIndex : Index → IO Index
  voucherMint : (writeCap : ByteArray) → (name : String) → IO Minted
  /-- The voucher stream's write and read caps. -/
  voucherDeriveStream : (voucher : ByteArray) → IO (ByteArray × ByteArray)
  voucherInduct : (voucher payload whoReply : ByteArray) → IO Inducted
  voucherOpen : (secretKey sealedReply writeCap : ByteArray) → IO Opened
  /-- The replica epoch the storage replicas are in, once known. -/
  replicaEpoch : IO (Option Nat)
  /-- The most plaintext a box holds. -/
  maxPlaintext : IO Nat

def indexSize : Nat := 104

/-- The index a write cap starts at. -/
def startOfWriteCap (writeCap : ByteArray) : Index := writeCap.extract (writeCap.size - indexSize) writeCap.size

/-- The read cap of the stream a write cap writes. -/
def readCapOf (writeCap : ByteArray) : ByteArray := writeCap.extract 32 writeCap.size

end Posse
