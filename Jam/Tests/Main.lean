/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Presentation
import GroupChatClient.GroupChatKatzenqt1.Tests.Net
import Jam.Tests.Util
import Jam.Tests.Security
import Jam.Ui
import Jam.Tests.Drive

/-! # jam's tests

In one process, with no daemon: what reaches the screen, the interface driven by keys, and
commands. The core is tested in group_chat_client. -/

namespace Jam.Tests

open CryptWalker.Protocols.GroupComm.Common
open CryptWalker.Protocols.GroupComm.GroupChatKatzenqt1.Member
open GroupChatClient GroupChatClient.GroupChatKatzenqt1
open GroupChatClient.GroupChatKatzenqt1.Tests (Net NetM feed runUntil code? joined noticed chatOf)

def newNet (names : List String) : IO (IO.Ref Sim.World × Net) := do
  let world ← IO.mkRef ({} : Sim.World)
  pure (world, { cores := names.toArray.map fun me => { present := presentation, state := { me } } })

/-- `/remove` names a member by display name or by the start of their key. -/
def removeByName : TestM Unit := do
  let (world, net) ← newNet ["alice", "bob"]
  let (ok, net) ← (do
    feed 0 (.create "g")
    feed 1 (.join "g")
    unless ← runUntil world fun n => (code? n 1 "g").isSome do return false
    let some code := code? (← get) 1 "g" | return false
    feed 0 (.induct "g" code)
    runUntil world fun n => joined n 1 "g" && noticed n 0 "g" "added ~bob").run net
  check "bob joins alice's group" ok
  let u : Ui.Ui := { state := net.cores[0]!.state }
  let bob := ((chatOf net 1 "g").bind (·.group)).map (·.me) |>.getD .empty
  check "/remove finds a member by name" (match (Ui.command u "/remove bob").1 with
    | some (.remove "g" k) => k == bob
    | _ => false)
  check "/remove finds a member by the start of their key" (match (Ui.command u s!"/remove {(hex bob).take 6}").1 with
    | some (.remove "g" k) => k == bob
    | _ => false)
  check "/remove names no one it cannot find"
    ((Ui.command u "/remove dave").2.2.1 == "no member is called dave")

def ui : TestM Unit := do
  let chat : Chat :=
    { name := "g", names := Dict.ofList [(ByteArray.mk #[1], "bob")],
      log := [{ id := 0, sender := ByteArray.mk #[1], text := "hello from bob" },
              { id := 1, text := "bob added carol" }] }
  let u : Ui.Ui := { state := { me := "alice", chats := [chat] } }
  let has (lines : List String) (s : String) := lines.any fun l => (l.splitOn s).length > 1
  let shown := ((Ui.draw u).draw 100 30).lines
  check "the conversation is drawn" (has shown "hello from bob" && has shown "~bob")
  check "a notice is drawn" (has shown "-- bob added carol")
  check "the input line names its group" (has shown "[g]")
  check "the header names jam and the group" (has shown "≋ jam" && has shown " g ")
  let hidden := ((Ui.draw { u with showLog := false }).draw 100 30).lines
  check "F2's pane can be hidden" (!has hidden "log · F2")
  check "the log pane is shown" (has shown "log · F2")
  check "with no group, the welcome shows how to start"
    (has ((Ui.draw { state := { me := "alice" } }).draw 100 30).lines "/new NAME")
  let d ← drive u (line "hi there")
  check "enter sends the line to the selected group" (match d.sent.toList with
    | [.send "g" "hi there"] => true
    | _ => false)
  check "enter clears the line" (d.ui.input.length == 0 && !d.quit)
  let d ← drive u (line "/new h")
  check "/new creates a group" (match d.sent.toList with
    | [.create "h"] => true
    | _ => false)
  let d ← drive u (line "/new h" ++ [.custom (.state { me := "alice", chats := [chat, { name := "h" }] })])
  check "the new group is selected once it appears" (d.ui.selected == 1)
  let u4 := { d.ui with note := "" }
  check "escape quits" (← drive u4 [key .esc]).quit
  let d ← drive u4 (line "/join h")
  check "/join under a name already used is refused, and says why"
    (d.sent.isEmpty && d.ui.note.startsWith "you already have a group called h")
  let d ← drive u4 (line "/new g")
  check "so is /new" (d.sent.isEmpty && d.ui.note.startsWith "you already have a group called g")
  let d ← drive u4 (line "/leave")
  check "/leave asks for the group's name" (d.ui.note.startsWith "to leave h")
  let d ← drive u4 (line "/leave h")
  check "/leave with the group's name leaves" (match d.sent.toList with
    | [.leave "h"] => true
    | _ => false)
  check "an unknown command says so" ((← drive u4 (line "/bogus")).ui.note.startsWith "no such command")
  -- Easier to use
  let d ← drive u (typed "/inv" ++ [key .tab])
  check "Tab completes a command" (d.ui.input.text.text == "/invite ")
  check "and does not change the group" (d.ui.selected == 0)
  check "a command being typed is hinted" ((Ui.hint (← drive u (typed "/inv")).ui).any fun h =>
    (h.text.splitOn "/invite CODE").length > 1)
  let d ← drive u4 [key .tab]
  check "Tab with nothing typed moves to the next group" (d.ui.selected == 0)
  let d ← drive u (line "first" ++ line "second" ++ [key .up, key .up])
  check "Up brings back what was sent" (d.ui.input.text.text == "first")
  let d ← drive u (typed "helo" ++ [key .left, key .left] ++ typed "l")
  check "the cursor moves, and typing goes in at it" (d.ui.input.text.text == "hello")
  let d ← drive u [key (.f 1)]
  check "F1 opens the help" (d.ui.help && has ((Ui.draw d.ui).draw 100 30).lines "/invite")
  let d ← drive u [key (.f 1), key .esc]
  check "Esc closes it, and does not quit" (!d.ui.help && !d.quit)
  check "/help opens it too" (← drive u (line "/help")).ui.help
  let long := ((Ui.draw { u with state := { me := "alice", chats := [{ name := "claude-demo" }] } }).draw 100 30).lines
  check "a group's whole name is shown in the list" (has long "│claude-demo")
  check "a group not joined yet says so" (has long "not joined yet")
  let two := { u with state := { me := "alice", chats := [chat, { name := "h" }] } }
  let d ← drive two [click 3 3]
  check "a click selects a group" (d.ui.selected == 1)
  let d ← drive two [click 50 5]
  check "a click elsewhere does not" (d.ui.selected == 0)
  let d ← drive { u with scroll := 0 } [.terminal (.mouse { kind := .scrollUp, column := 50, row := 5 })]
  check "the wheel scrolls the conversation" (d.ui.scroll == 3)
  let d ← drive u [paste "one\ntwo\nthree"]
  check "a paste of several lines is shown as such"
    (has ((Ui.draw d.ui).draw 100 30).lines "3 lines pasted")

def main : IO UInt32 := do
  let ((), (pass, fail)) ← (do
    Security.tests
    ui
    removeByName).run (0, 0)
  IO.println s!"{pass} passed, {fail} failed"
  return if fail == 0 then 0 else 1

end Jam.Tests

def main : IO UInt32 := Jam.Tests.main
