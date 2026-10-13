/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Exec
import Jam.Tests.Sim

/-! # Members on a simulated network

Several jam cores over one `Sim` world, in one process. Actions run one at a time, in order;
what is to happen later waits on a logical clock, which jumps to the next thing due whenever
nothing else is left to do. -/

namespace Jam.Tests

open CryptWalker.GroupChat.Member

inductive Later
  | act (a : Action)
  | msg (m : Msg)

structure Net where
  cores : Array Core
  queue : Array (Nat × Action) := #[]
  later : Array (Nat × Nat × Later) := #[]
  clock : Nat := 0

abbrev NetM := StateT Net IO

def backend (world : IO.Ref Sim.World) : Backend := Sim.backend world

def feed (who : Nat) (m : Msg) : NetM Unit := do
  let n ← get
  let (c, as) := step n.cores[who]! m
  set { n with cores := n.cores.set! who c, queue := n.queue ++ as.toArray.map (who, ·) }

/-- Run one action, or move the clock on; `false` when there is nothing left at all. -/
def tick (world : IO.Ref Sim.World) : NetM Bool := do
  let n ← get
  if h : 0 < n.queue.size then
    let (who, a) := n.queue[0]
    set { n with queue := n.queue.extract 1 n.queue.size }
    match ← perform (backend world) a with
    | .done m => feed who m
    | .retry a ms => modify fun n => { n with later := n.later.push (n.clock + ms, who, .act a) }
    | .delay m ms => modify fun n => { n with later := n.later.push (n.clock + ms, who, .msg m) }
    return true
  match (n.later.map (·.1)).toList.min? with
  | none => return false
  | some due =>
    let (now, rest) := n.later.partition (·.1 ≤ due)
    set { n with later := rest, clock := due }
    for (_, who, l) in now do
      match l with
      | .act a => modify fun n => { n with queue := n.queue.push (who, a) }
      | .msg m => feed who m
    return true

/-- Run until `done` holds or the clock passes `limit` milliseconds from now. -/
def runUntil (world : IO.Ref Sim.World) (done : Net → Bool) (limit : Nat := 600000) : NetM Bool := do
  let start := (← get).clock
  while !(done (← get)) do
    if (← get).clock > start + limit then return false
    unless ← tick world do return done (← get)
  return true

def chatOf (n : Net) (who : Nat) (name : String) : Option Chat := n.cores[who]!.state.chat? name

def says (n : Net) (who : Nat) (name : String) (text : String) : Bool :=
  (chatOf n who name).any fun c => c.log.any (·.text == text)

/-- A notice of jam's that begins with `text`. -/
def noticed (n : Net) (who : Nat) (name : String) (text : String) : Bool :=
  (chatOf n who name).any fun c => c.log.any fun l => l.sender.size == 0 && l.text.startsWith text

def joined (n : Net) (who : Nat) (name : String) : Bool :=
  (chatOf n who name).any (·.group.isSome)

def code? (n : Net) (who : Nat) (name : String) : Option String := do
  match (← chatOf n who name).joining with
  | some (.awaiting code ..) => some code
  | _ => none

end Jam.Tests
