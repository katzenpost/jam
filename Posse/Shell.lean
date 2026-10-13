/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Logger
import Std.Sync.Channel
import Posse.Exec

/-! # Running posse

One task owns the core: it takes each message in turn, steps the core, saves the state, shows it,
and launches the network work the step asks for, each on a task of its own that hands back what
came of it. Another task watches the replica epoch. -/

namespace Posse

open CryptWalker.GroupChat.Member
open CryptWalker.GroupChat.Member.Persist
open Logger

def hex (b : ByteArray) : String :=
  String.join (b.data.toList.map fun x =>
    let s := String.ofList (Nat.toDigits 16 x.toNat)
    if s.length < 2 then "0" ++ s else s)

/-- The first bytes of `b` in hex, enough to tell streams apart in a log. -/
def short (b : ByteArray) : String := hex (b.extract 0 4)

def Msg.describe : Msg → String
  | .create chat => s!"{chat}: create"
  | .join chat => s!"{chat}: join"
  | .induct chat _ => s!"{chat}: add a member"
  | .send chat text => s!"{chat}: send {text.length} characters"
  | .scan chat => s!"{chat}: scan"
  | .created chat joining _ => s!"{chat}: created a stream{if joining then " to join with" else ""}"
  | .wrote chat job index _ => s!"{chat}: wrote job {job} at box {counter index}"
  | .read chat stream index o =>
    let what := match o with
      | .data p _ => s!"{p.size} bytes"
      | .notFound => "nothing yet"
      | .tombstone _ => "a tombstone"
    s!"{chat}: read {short stream} box {counter index}: {what}"
  | .wake chat stream => s!"{chat}: read {short stream} again"
  | .scanRead chat stream index _ => s!"{chat}: scan read {short stream} box {counter index}"
  | .walked chat stream _ skipped steps =>
    s!"{chat}: walked {short stream} {steps} steps, {skipped.length} kept"
  | .derived chat stream indexes => s!"{chat}: derived {indexes.length} indexes of {short stream}"
  | .minted chat _ box1 => s!"{chat}: minted a voucher; its reply goes to box {counter box1}"
  | .opened chat _ => s!"{chat}: opened the voucher's reply"
  | .joinerPayload chat _ _ _ _ => s!"{chat}: read a voucher's box 0"
  | .inducted chat i => s!"{chat}: sealed the reply for {i.name}"
  | .epoch n => s!"replica epoch {n}"
  | .failed chat what => s!"{chat}: {what}"

structure Shell where
  backend : Backend
  core : IO.Ref Core
  inbox : Std.CloseableChannel Msg
  log : Logger
  statePath : System.FilePath
  /-- Called with the state after each step. -/
  display : State → IO Unit
  stop : IO.Ref Bool

namespace Shell

def post (sh : Shell) (m : Msg) : IO Unit := discard <| sh.inbox.send m

/-- Sleep `ms` milliseconds, waking early when posse stops; whether it is still running. -/
partial def nap (sh : Shell) (ms : Nat) : IO Bool := do
  if ← sh.stop.get then return false
  if ms = 0 then return true
  let slice := min ms 500
  IO.sleep slice.toUInt32
  nap sh (ms - slice)

partial def launch (sh : Shell) (a : Action) : IO Unit := do
  let net := sh.log.withModule "posse/net"
  discard <| IO.asTask (prio := .dedicated) do
    net.debug (describe a)
    match ← perform sh.backend a with
    | .done m => sh.post m
    | .retry a ms =>
      net.info s!"{describe a}: trying again in {ms} ms"
      if ← nap sh ms then launch sh a
    | .delay m ms => if ← nap sh ms then sh.post m

def save (sh : Shell) (s : State) : IO Unit := do
  let tmp := sh.statePath.addExtension "tmp"
  IO.FS.writeBinFile tmp (Persist.save s)
  IO.FS.rename tmp sh.statePath

/-- Take messages until posse stops. -/
partial def drive (sh : Shell) : IO Unit := do
  let log := sh.log.withModule "posse/driver"
  let some m ← IO.wait (← sh.inbox.recv) | return
  if ← sh.stop.get then return
  log.debug m.describe
  if let .failed _ what := m then log.warning what
  let (c, actions) := step (← sh.core.get) m
  sh.core.set c
  try sh.save c.state
  catch e => (sh.log.withModule "posse/store").error s!"saving: {e}"
  sh.display c.state
  for a in actions do launch sh a
  drive sh

/-- Tell the core the replica epoch each minute. -/
partial def watchEpoch (sh : Shell) : IO Unit := do
  try
    if let some n ← sh.backend.replicaEpoch then sh.post (.epoch n)
  catch e => (sh.log.withModule "posse/net").warning s!"replica epoch: {e}"
  if ← nap sh 60000 then watchEpoch sh

/-- Start the driver and the epoch watcher, and whatever the saved state had under way. -/
def start (sh : Shell) (resumed : List Action) : IO Unit := do
  discard <| IO.asTask (prio := .dedicated) sh.drive
  discard <| IO.asTask (prio := .dedicated) sh.watchEpoch
  for a in resumed do launch sh a

end Shell

end Posse
