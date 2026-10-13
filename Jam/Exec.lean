/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import CryptWalker.GroupChat.Member.Walk
import Jam.Core

/-! # Carrying out an action

`perform` does one `Action` on a `Backend` and says what came of it: a message for the core, or
that it is to be tried again later. Waiting is left to the caller, so that the app can sleep and a
test can step a simulated clock. -/

namespace Jam

open CryptWalker.GroupChat.Member

inductive Outcome
  | done (m : Msg)
  /-- Try the action again after `ms` milliseconds. -/
  | retry (a : Action) (ms : Nat)
  /-- Hand the core `m` after `ms` milliseconds. -/
  | delay (m : Msg) (ms : Nat)

/-- How long to wait before writing again after a failure, or reading a voucher box again. -/
def retryMs : Nat := 5000

/-- Write a box, trying again until it is written. -/
partial def publish (b : Backend) (writeCap : ByteArray) (index : Index) (box : ByteArray) :
    IO Index := do
  try b.writeBox writeCap index box
  catch _ =>
    IO.sleep retryMs.toUInt32
    publish b writeCap index box

def describe : Action → String
  | .create chat joining => s!"{chat}: new stream{if joining then " to join with" else ""}"
  | .write chat job _ index box => s!"{chat}: write job {job} to box {counter index} ({box.size} bytes)"
  | .read chat _ _ index => s!"{chat}: read box {counter index}"
  | .wake chat _ ms => s!"{chat}: read again in {ms} ms"
  | .scanRead chat _ _ index => s!"{chat}: scan reads box {counter index}"
  | .walk chat _ start targets _ => s!"{chat}: walk from {counter start} to {targets}"
  | .derive chat _ start n => s!"{chat}: derive {n} indexes after {counter start}"
  | .mint chat .. => s!"{chat}: mint a voucher"
  | .awaitReply chat _ _ box1 _ => s!"{chat}: wait for the voucher's reply in box {counter box1}"
  | .readVoucher chat _ => s!"{chat}: read a voucher's box 0"
  | .induct chat .. => s!"{chat}: seal the reply to a voucher"

def perform (b : Backend) (a : Action) : IO Outcome := do
  try
    match a with
    | .create chat joining => return .done (.created chat joining (← b.newKeypair))
    | .write chat job wc index box =>
      try return .done (.wrote chat job index (← b.writeBox wc index box))
      catch _ => return .retry a retryMs
    | .read chat stream rc index => return .done (.read chat stream index (← b.readBox rc index))
    | .wake chat stream ms => return .delay (.wake chat stream) ms
    | .scanRead chat stream rc index =>
      return .done (.scanRead chat stream index (← b.readBox rc index))
    | .walk chat stream start targets keep =>
      let (target, skipped, steps) ← walkWith b.nextIndex start targets keep
      return .done (.walked chat stream target skipped steps)
    | .derive chat stream start count =>
      return .done (.derived chat stream (← deriveWith b.nextIndex start count))
    | .mint chat wc name =>
      let m ← b.voucherMint wc name
      let box1 ← publish b m.writeCap (startOfWriteCap m.writeCap) m.payload
      return .done (.minted chat m box1)
    | .awaitReply chat sk vrc box1 wc =>
      match ← b.readBox vrc box1 with
      | .data sealed _ => return .done (.opened chat (← b.voucherOpen sk sealed wc))
      | .notFound => return .retry a retryMs
      | .tombstone _ => return .done (.failed chat "the voucher's reply was withdrawn")
    | .readVoucher chat voucher =>
      let (vwc, vrc) ← b.voucherDeriveStream voucher
      match ← b.readBox vrc (startOf vrc) with
      | .data payload box1 => return .done (.joinerPayload chat voucher vwc payload box1)
      | .notFound => return .retry a retryMs
      | .tombstone _ => return .done (.failed chat "that voucher was withdrawn")
    | .induct chat voucher payload who vwc box1 =>
      let i ← b.voucherInduct voucher payload who
      discard <| publish b vwc box1 i.sealedReply
      return .done (.inducted chat i)
  catch e =>
    let chat := match a with
      | .create c .. | .write c .. | .read c .. | .wake c .. | .scanRead c .. | .walk c ..
      | .derive c .. | .mint c .. | .awaitReply c .. | .readVoucher c .. | .induct c .. => c
    match a with
    | .read .. | .scanRead .. => return .retry a retryMs
    | _ => return .done (.failed chat s!"{describe a} failed: {e}")

end Jam
