/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Tessera
import Posse.Core

/-! # The terminal UI

The groups on the left, the selected conversation in the middle, and on the right everyone who
reads what is written there, each with the start of their key, since a display name is only what
its owner chose. Below, the log, which F2 hides, then the line to type into, which names the group
it goes to. A line beginning with `/` is a command. -/

namespace Posse.Ui

open Tessera Widget
open CryptWalker.GroupChat.Member

inductive Event
  | state (s : State)
  | logs (lines : Array String)

structure Ui where
  state : State
  selected : Nat := 0
  input : String := ""
  /-- Rows scrolled back from the end of the conversation. -/
  scroll : Nat := 0
  /-- A group asked for, to select once it appears. -/
  want : Option String := none
  note : String := ""
  logs : Array String := #[]
  showLog : Bool := true
  /-- How many lines of each conversation have been shown. -/
  seen : List (String × Nat) := []
  /-- What posse is connected to. -/
  network : String := ""
  deriving Inhabited

def help : String :=
  "/new NAME · /join NAME · /invite CODE · /scan · /quit · Tab next group · PgUp PgDn scroll · F2 log"

def logRows : Nat := 6

def current (u : Ui) : Option Chat := u.state.chats[u.selected]?

def hexByte (b : UInt8) : String :=
  let s := String.ofList (Nat.toDigits 16 b.toNat)
  if s.length < 2 then "0" ++ s else s

/-- The start of a member's key. -/
def fingerprint (key : ByteArray) : String := String.join ((key.extract 0 2).data.toList.map hexByte) ++ "…"

def lineText (c : Chat) (l : Line) : String :=
  if l.sender.size = 0 then s!"-- {l.text}"
  else
    let mine := c.group.any (·.me == l.sender)
    let mark := if !mine then "" else match l.status with
      | .pending => " …"
      | .sent => if acknowledged c l then " ✓✓" else " ✓"
    s!"{c.nameOf l.sender}: {l.text}{mark}"

/-- Rows, wrapped to the width, the last of them at the bottom unless scrolled back. -/
def bottomUp (rows : List String) (scroll : Nat) : Widget where
  hPolicy := .greedy
  vPolicy := .greedy
  render ctx :=
    let wrapped := rows.flatMap (wrap ctx.width)
    let offset := wrapped.length - min wrapped.length (ctx.height + scroll)
    (viewport offset (vBox (wrapped.map str))).render ctx

def pickList (rows : List String) (selected : Nat) : Widget where
  hPolicy := .greedy
  vPolicy := .greedy
  render ctx :=
    let offset := selected + 1 - min (selected + 1) ctx.height
    let row (i : Nat) (s : String) :=
      if i == selected then vLimit 1 (withStyle { reverse := true } (hBox [str s, fill])) else str s
    (viewport offset (vBox (rows.zipIdx.map fun (s, i) => row i s))).render ctx

def unread (u : Ui) (c : Chat) : Nat := c.log.length - ((u.seen.lookup c.name).getD 0)

def groupRow (u : Ui) (c : Chat) : String :=
  let n := unread u c
  let state := if c.joining.isSome then " joining…" else if c.inducting.isSome then " adding…"
    else if c.group.isNone then " …" else ""
  s!"{c.name}{if n > 0 then s!" ({n})" else ""}{state}"

/-- Everyone who reads the group, ourselves first. A name two members share is marked. -/
def members (c : Chat) : List String :=
  match c.group with
  | none => []
  | some g =>
    let others := g.readers.keys.map fun k => ((c.names.get? k).getD "?", k)
    let names := others.map (·.1)
    let row (name : String) (k : ByteArray) :=
      let dup := if names.count name > 1 then " (!)" else ""
      s!"{name}{dup} {fingerprint k}"
    row "me" g.me :: (others.mergeSort (fun a b => a.1 ≤ b.1)).map fun (n, k) => row n k

def status (u : Ui) : String :=
  let pending := u.state.chats.foldl (fun n c => n + c.jobs.length) 0
  let epoch := match (current u).bind (·.group) with
    | some g => s!"epoch {g.epoch} · "
    | none => ""
  let note := if u.note.isEmpty then "F1 help" else u.note
  s!" {epoch}{pending} to write · {u.network} · {note}"

def draw (u : Ui) : Widget :=
  let (title, rows, who) := match current u with
    | some c => (s!" {c.name} ", c.log.map (lineText c), members c)
    | none => (" posse ", ["No groups yet.", "", help], [])
  let target := match current u with
    | some c => s!" [{c.name}] > "
    | none => " > "
  let top := hBox [
    hLimit 22 (borderWithLabel " groups " (pickList (u.state.chats.map (groupRow u)) u.selected)),
    borderWithLabel title (bottomUp rows u.scroll),
    hLimit 24 (borderWithLabel " members " (vBox ((who.map str) ++ [fill])))]
  let log := if u.showLog then [vLimit (logRows + 2) (borderWithLabel " log (F2 hides) "
    (bottomUp u.logs.toList 0))] else []
  vBox ([top] ++ log ++ [
    vLimit 3 (borderWithLabel " message, or /command " (hBox [
      withStyle (Style.fgOf .cyan) (str target), str u.input,
      withStyle { reverse := true } (str " "), fill])),
    withStyle { dim := true } (str (status u))])

/-- What a line typed asks for: a message for the core, a group to select, a note, and whether
to quit. -/
def command (u : Ui) (line : String) : Option Msg × Option String × String × Bool :=
  let words := (line.trimAscii.toString.splitOn " ").filter (· ≠ "")
  let rest := " ".intercalate (words.drop 1)
  let chat := (current u).map (·.name)
  match words.head? with
  | some "/quit" => (none, none, "", true)
  | some "/new" =>
    if rest.isEmpty then (none, none, "/new NAME", false) else (some (.create rest), some rest, "", false)
  | some "/join" =>
    if rest.isEmpty then (none, none, "/join NAME", false) else (some (.join rest), some rest, "", false)
  | some "/invite" =>
    match chat with
    | some c => if rest.isEmpty then (none, none, "/invite CODE", false) else (some (.induct c rest), none, "", false)
    | none => (none, none, "select a group first", false)
  | some "/scan" => (chat.map .scan, none, "", false)
  | some "/help" => (none, none, help, false)
  | some w =>
    if w.startsWith "/" then (none, none, s!"no such command: {w}", false)
    else match chat with
      | some c => (some (.send c line), none, "", false)
      | none => (none, none, "create or join a group first: /new NAME or /join NAME", false)
  | none => (none, none, "", false)

/-- Count the selected conversation as read. -/
def markSeen (u : Ui) : Ui :=
  match current u with
  | some c => { u with seen := (c.name, c.log.length) :: u.seen.filter (·.1 != c.name) }
  | none => u

def select (u : Ui) (i : Nat) : Ui := markSeen { u with selected := i, scroll := 0 }

def update (send : Msg → IO Unit) : Tessera.Msg Event → Ui → IO (Ui × Bool)
  | .custom (.state s), u =>
    let selected := match u.want with
      | some w => (s.chats.findIdx? (·.name == w)).getD u.selected
      | none => u.selected
    let want := u.want.filter fun w => !s.chats.any (·.name == w)
    pure (markSeen { u with state := s, selected := min selected (s.chats.length - 1), want }, false)
  | .custom (.logs lines), u => pure ({ u with logs := lines }, false)
  | .input (.key .esc _), u => pure (u, true)
  | .input (.key (.char 'c') { ctrl := true, .. }), u => pure (u, true)
  | .input (.key (.f 1) _), u => pure ({ u with note := if u.note == help then "" else help }, false)
  | .input (.key (.f 2) _), u => pure ({ u with showLog := !u.showLog }, false)
  | .input (.key .tab _), u =>
    let n := u.state.chats.length
    pure (select u (if n = 0 then 0 else (u.selected + 1) % n), false)
  | .input (.key .backTab _), u =>
    let n := u.state.chats.length
    pure (select u (if n = 0 then 0 else (u.selected + n - 1) % n), false)
  | .input (.key .pageUp _), u => pure ({ u with scroll := u.scroll + 10 }, false)
  | .input (.key .pageDown _), u => pure ({ u with scroll := u.scroll - 10 }, false)
  | .input (.key .backspace _), u =>
    pure ({ u with input := (u.input.dropEnd 1).toString }, false)
  | .input (.key .enter _), u => do
    let (m, want, note, quit) := command u u.input
    if let some m := m then send m
    pure ({ u with input := "", want := want.orElse fun _ => u.want, note, scroll := 0 }, quit)
  | .input (.key (.char c) m), u =>
    if m.ctrl || m.alt then pure (u, false) else pure ({ u with input := u.input.push c }, false)
  | .input (.paste text), u => pure ({ u with input := u.input ++ text.trimAscii.toString }, false)
  | _, u => pure (u, false)

end Posse.Ui
