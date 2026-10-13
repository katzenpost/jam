/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Posse.Tests.Net
import Posse.Ui

/-! # posse's tests

In one process, with no daemon: the codecs posse adds, and members chatting over a simulated
Pigeonhole. -/

namespace Posse.Tests

open CryptWalker.GroupChat.Member
open CryptWalker.GroupChat.Member.Persist

abbrev TestM := StateT (Nat × Nat) IO

def check (name : String) (ok : Bool) : TestM Unit := do
  let (pass, fail) ← get
  if ok then set (pass + 1, fail)
  else
    IO.println s!"FAIL {name}"
    set (pass, fail + 1)

def base64 : TestM Unit := do
  for (raw, text) in [("", ""), ("a", "YQ=="), ("ab", "YWI="), ("abc", "YWJj"),
      ("hello world", "aGVsbG8gd29ybGQ=")] do
    check s!"base64 encodes {raw}" (Base64.encode raw.toUTF8 == text)
    check s!"base64 decodes {text}" ((Base64.decode text).map (·.data) == some raw.toUTF8.data)
  let bytes : ByteArray := ⟨(List.range 256).toArray.map (·.toUInt8)⟩
  check "base64 round trip" ((Base64.decode (Base64.encode bytes)).map (·.data) == some bytes.data)
  check "base64 refuses junk" (Base64.decode "abc!" |>.isNone)

def newNet (n : Nat) (names : List String) : IO (IO.Ref Sim.World × Net) := do
  let world ← IO.mkRef ({} : Sim.World)
  pure (world, { cores := (names.take n).toArray.map fun me => { state := { me } } })

/-- Alice founds "g", Bob joins with a voucher Alice inducts. -/
def foundAndJoin (world : IO.Ref Sim.World) : NetM Bool := do
  feed 0 (.create "g")
  feed 1 (.join "g")
  unless ← runUntil world fun n => (code? n 1 "g").isSome do return false
  let some code := code? (← get) 1 "g" | return false
  feed 0 (.induct "g" code)
  runUntil world fun n => joined n 1 "g" && says n 0 "g" "added bob"

def twoMembers : TestM Unit := do
  let (world, net) ← newNet 2 ["alice", "bob"]
  let (ok, net) ← (do
    unless ← foundAndJoin world do return (false, false, false, false)
    feed 1 (.send "g" "hi from bob")
    feed 0 (.send "g" "hi from alice")
    let both ← runUntil world fun n => says n 0 "g" "hi from bob" && says n 1 "g" "hi from alice"
    -- Bob acknowledges what he read in his next message.
    feed 1 (.send "g" "read you")
    let acked ← runUntil world fun n => (chatOf n 0 "g").any fun (c : Chat) =>
      c.log.any fun l => l.text == "hi from alice" && acknowledged c l
    let n ← get
    let idle := n.cores.all fun c => c.state.chats.all (·.jobs.isEmpty)
    return (true, both, acked, idle)).run net
  let (joinedOk, both, acked, idle) := ok
  check "bob joins alice's group" joinedOk
  check "alice and bob read each other" both
  check "bob's message acknowledges alice's" acked
  check "nothing is left to write" idle
  let names := (net.cores[0]!.state.chat? "g").map fun (c : Chat) => c.names.values
  check "alice knows bob by name" (names.any fun (ns : List String) => ns.contains "bob")

def threeMembers : TestM Unit := do
  let (world, net) ← newNet 3 ["alice", "bob", "carol"]
  let (ok, _) ← (do
    unless ← foundAndJoin world do return (false, false)
    -- Carol joins through Bob; Alice learns of her from Bob's Introduction.
    feed 2 (.join "g")
    unless ← runUntil world fun n => (code? n 2 "g").isSome do return (false, false)
    let some code := code? (← get) 2 "g" | return (false, false)
    feed 1 (.induct "g" code)
    unless ← runUntil world fun n => joined n 2 "g" && says n 0 "g" "bob added carol" do
      return (false, false)
    feed 2 (.send "g" "carol here")
    feed 0 (.send "g" "welcome carol")
    let all ← runUntil world fun n =>
      says n 0 "g" "carol here" && says n 1 "g" "carol here" && says n 2 "g" "welcome carol"
    return (true, all)).run net
  check "carol joins through bob, and alice hears of it" ok.1
  check "all three read each other" ok.2

def removeAndLeave : TestM Unit := do
  let (world, net) ← newNet 3 ["alice", "bob", "carol"]
  let (ok, _) ← (do
    unless ← foundAndJoin world do return (false, false, false, false, false)
    feed 2 (.join "g")
    unless ← runUntil world fun n => (code? n 2 "g").isSome do return (false, false, false, false, false)
    let some code := code? (← get) 2 "g" | return (false, false, false, false, false)
    feed 0 (.induct "g" code)
    unless ← runUntil world fun n => joined n 2 "g" && says n 1 "g" "alice added carol" do
      return (false, false, false, false, false)
    feed 2 (.send "g" "carol before")
    discard <| runUntil world fun n => says n 0 "g" "carol before" && says n 1 "g" "carol before"
    -- Alice stops reading Carol; Bob does not.
    feed 0 (.remove "g" "carol")
    let n ← get
    let gone := (chatOf n 0 "g").any fun (c : Chat) =>
      c.group.any (fun (g : Group) => g.readers.size == 1) && !c.log.any (·.text == "carol before")
    feed 2 (.send "g" "carol after")
    feed 1 (.send "g" "bob after")
    let bobHears ← runUntil world fun n => says n 1 "g" "carol after" && says n 0 "g" "bob after"
    let aliceDoesNot := !says (← get) 0 "g" "carol after"
    let unknown := (feed 0 (.remove "g" "dave") *> get : NetM Net)
    let n ← unknown
    let refused := says n 0 "g" "no member is called dave"
    -- Bob leaves; what was under way for the group comes to nothing.
    feed 1 (.leave "g")
    discard <| runUntil world (fun _ => false) 60000
    let left := (chatOf (← get) 1 "g").isNone
    return (gone, bobHears && aliceDoesNot, refused, left, true)).run net
  let (gone, others, refused, left, _) := ok
  check "remove stops reading a member and deletes what they sent" gone
  check "the others still read the removed member, who still reads them" others
  check "remove names no one it cannot find" refused
  check "leave deletes the group" left

def restart : TestM Unit := do
  let (world, net) ← newNet 2 ["alice", "bob"]
  let (ok, net) ← (do
    let j ← foundAndJoin world
    feed 0 (.send "g" "before")
    let r ← runUntil world fun n => says n 1 "g" "before"
    return j && r).run net
  check "a conversation before restarting" ok
  -- Alice stops, is saved, loads and carries on.
  let saved := save net.cores[0]!.state
  let loaded : Option State := load saved
  check "alice's state loads as saved" (loaded.isSome)
  let some s := loaded | return
  let (core, actions) := resume s 1530
  let net := { net with cores := net.cores.set! 0 core,
                        queue := net.queue.filter (·.1 != 0) ++ actions.toArray.map (0, ·),
                        later := net.later.filter (·.2.1 != 0) }
  let (ok, _) ← (do
    feed 0 (.send "g" "after")
    feed 1 (.send "g" "bob after")
    runUntil world fun n => says n 1 "g" "after" && says n 0 "g" "bob after").run net
  check "alice carries on after restarting" ok

def failingWrites : TestM Unit := do
  let (world, net) ← newNet 2 ["alice", "bob"]
  let (ok, _) ← (do
    unless ← foundAndJoin world do return false
    world.modify fun w => { w with failWrites := 3 }
    feed 0 (.send "g" "eventually")
    runUntil world fun n => says n 1 "g" "eventually").run net
  check "a write that fails is tried again" ok

def tooLong : TestM Unit := do
  let (world, net) ← newNet 2 ["alice", "bob"]
  let (ok, _) ← (do
    feed 0 (.create "g")
    discard <| runUntil world fun n => joined n 0 "g"
    feed 0 (.send "g" (String.ofList (List.replicate 2000 'x')))
    let n ← get
    return (chatOf n 0 "g").any fun (c : Chat) =>
      c.jobs.isEmpty && c.log.any (·.text == "that message is too long to send")).run net
  check "a message too long for a box is refused" ok

def backfill : TestM Unit := do
  let (world, net) ← newNet 2 ["alice", "bob"]
  let (ok, _) ← (do
    unless ← foundAndJoin world do return (false, false)
    feed 0 (.send "g" "one")
    discard <| runUntil world fun n => says n 1 "g" "one"
    let before := (← world.get).writes.size
    -- A new replica epoch: each member rewrites its boxes, with the bytes first written.
    for e in [2, 3] do
      feed 0 (.epoch e)
      feed 1 (.epoch e)
      discard <| runUntil world fun n => n.cores.all fun c => c.state.chats.all (·.jobs.isEmpty)
    let w ← world.get
    let n ← get
    let rewrote := w.writes.size > before
    let idle := n.cores.all fun c => c.state.chats.all (·.jobs.isEmpty)
    return (rewrote, idle)).run net
  check "a new epoch rewrites boxes" ok.1
  check "every rewrite is accepted" ok.2

def persistState : TestM Unit := do
  let s : State := { me := "alice", chats := [{ name := "g", log := [{ id := 0, text := "x" }] }] }
  let back : Option State := load (save s)
  check "state saves and loads" (back.any fun b => b.me == "alice" && b.chats.length == 1)

def ui : TestM Unit := do
  let sent ← IO.mkRef (#[] : Array Msg)
  let send := fun m => sent.modify (·.push m)
  let chat : Chat :=
    { name := "g", names := Dict.ofList [(ByteArray.mk #[1], "bob")],
      log := [{ id := 0, sender := ByteArray.mk #[1], text := "hello from bob" },
              { id := 1, text := "bob added carol" }] }
  let u : Ui.Ui := { state := { me := "alice", chats := [chat] } }
  let shown := ((Ui.draw u).draw 100 30).lines
  check "the conversation is drawn" (shown.any fun l => (l.splitOn "bob: hello from bob").length > 1)
  check "a notice is drawn" (shown.any fun l => (l.splitOn "-- bob added carol").length > 1)
  check "the input line names its group" (shown.any fun l => (l.splitOn "[g] >").length > 1)
  let hidden := ((Ui.draw { u with showLog := false }).draw 100 30).lines
  check "F2's pane can be hidden" (!hidden.any fun l => (l.splitOn " log (F2").length > 1)
  check "the log pane is shown" (shown.any fun l => (l.splitOn " log (F2").length > 1)
  let typed ← "hi there".toList.foldlM (fun u c => do
    pure (← Ui.update send (.input (.key (.char c) {})) u).1) u
  let (u2, quit) ← Ui.update send (.input (.key .enter {})) typed
  check "enter sends the line to the selected group" (match (← sent.get).toList with
    | [.send "g" "hi there"] => true
    | _ => false)
  check "enter clears the line" (u2.input.isEmpty && !quit)
  let (u3, _) ← Ui.update send (.input (.paste "/new h")) u2
  let (u3, _) ← Ui.update send (.input (.key .enter {})) u3
  check "/new creates a group" (match (← sent.get).toList.getLast? with
    | some (.create "h") => true
    | _ => false)
  let (u4, _) ← Ui.update send (.custom (.state { me := "alice", chats := [chat, { name := "h" }] })) u3
  check "the new group is selected once it appears" (u4.selected == 1)
  let (_, quit) ← Ui.update send (.input (.key .esc {})) u4
  check "escape quits" quit
  let (u6, _) ← Ui.update send (.input (.paste "/leave")) u4
  let (u6, _) ← Ui.update send (.input (.key .enter {})) u6
  check "/leave asks for the group's name" (u6.note.startsWith "to leave h")
  let (u6, _) ← Ui.update send (.input (.paste "/leave h")) u6
  let (_, _) ← Ui.update send (.input (.key .enter {})) u6
  check "/leave with the group's name leaves" (match (← sent.get).toList.getLast? with
    | some (.leave "h") => true
    | _ => false)
  let (u5, _) ← Ui.update send (.input (.paste "/bogus")) u4
  let (u5, _) ← Ui.update send (.input (.key .enter {})) u5
  check "an unknown command says so" (u5.note.startsWith "no such command")

def main : IO UInt32 := do
  let ((), (pass, fail)) ← (do
    ui
    base64
    persistState
    twoMembers
    threeMembers
    removeAndLeave
    restart
    failingWrites
    tooLong
    backfill).run (0, 0)
  IO.println s!"{pass} passed, {fail} failed"
  return if fail == 0 then 0 else 1

end Posse.Tests

def main : IO UInt32 := Posse.Tests.main
