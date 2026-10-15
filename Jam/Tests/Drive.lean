/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Ui

/-! # Driving the UI as the terminal would

Keys, pastes and clicks reach the UI only through Tessera's application loop, which alone can say
they came from the user. These run a scripted list of them, and of jam's own events, through it. -/

namespace Jam.Tests

open CryptWalker.GroupChat.Member
open GroupChatClient GroupChatClient.GroupChatKatzenqt1
open Tessera

/-- What came of driving the UI: its last state, what it sent the core, and whether it quit. -/
structure Driven where
  ui : Ui.Ui
  sent : Array Msg
  quit : Bool

/-- Run `events` through the UI from `u`, on a screen `w` by `h`. -/
def drive (u : Ui.Ui) (events : List (Incoming Ui.Event)) (w : Nat := 100) (h : Nat := 30) :
    IO Driven := do
  let sent ← IO.mkRef (#[] : Array Msg)
  let quit ← IO.mkRef false
  let queue ← IO.mkRef events
  let app : App Display.CS Ui.Ui Ui.Event :=
    { draw := Ui.draw,
      update := fun m u => do
        let (u, q) ← Ui.update (fun m => sent.modify (·.push m)) m u
        if q then quit.set true
        pure (u, q) }
  let screen : Screen := { size := pure (w, h), write := fun _ => pure () }
  let u ← app.loop screen (queue.modifyGet fun | [] => (none, []) | m :: r => (some m, r)) u
  return { ui := u, sent := ← sent.get, quit := ← quit.get }

def key (k : CrosstermFfi.Key) (m : Modifiers := {}) : Incoming Ui.Event := .terminal (.key k m)

def typed (s : String) : List (Incoming Ui.Event) := s.toList.map fun c => key (.char c)

/-- Type `s` and press Enter. -/
def line (s : String) : List (Incoming Ui.Event) := typed s ++ [key .enter]

def paste (s : String) : Incoming Ui.Event := .terminal (.paste s)

def click (column row : Nat) : Incoming Ui.Event :=
  .terminal (.mouse { kind := .down .left, column, row })

end Jam.Tests
