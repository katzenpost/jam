/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Tessera
import Posse.Core
import Posse.Display

/-! # The terminal UI

The groups on the left, the selected conversation in the middle, and on the right everyone who
reads what is written there, each with the start of their key, since a display name is only what
its owner chose. Below, the log, which F2 hides, then the line to type into, which names the group
it goes to. A line typed beginning with `/` is a command.

posse, not the sender, decides what each part of the screen says, as Yee's trusted path asks:

- Everything drawn is `Display.Shown`: text from the network has been filtered on its way.
- A member's own name is shown after `~`, as a name they chose; ours as `me`, which no member can
  take, since theirs always begins with `~`. A name that looks like another member's, or mixes
  scripts, also shows the start of its key.
- Every row a message takes after its first, whether its sender broke the line or it wraps, starts
  with a gutter, so a message cannot pass for another one below it.
- posse's own notices are drawn in a style no message has, and begin with `--`.
- Pasting into an empty line types a message, never a command, and a message of several lines is
  sent only on a second Enter, after posse has said how many lines it is. -/

namespace Posse.Ui

open Tessera Widget
open Posse.Display
open Tessera.Untrusted (skeleton mixedScript)
open CryptWalker.GroupChat.Member

inductive Event
  | state (s : State)
  | logs (lines : Array String)

structure Ui where
  state : State
  selected : Nat := 0
  input : String := ""
  /-- The line began with a paste, so it is a message whatever it says. -/
  pasted : Bool := false
  /-- A message of several lines that Enter has once been pressed for. -/
  confirming : Bool := false
  /-- Rows scrolled back from the end of the conversation. -/
  scroll : Nat := 0
  /-- A group asked for, to select once it appears. -/
  want : Option String := none
  note : String := ""
  logs : Array String := #[]
  showLog : Bool := true
  /-- The screen blanked, for someone looking over your shoulder. -/
  blank : Bool := false
  /-- How many lines of each conversation have been shown. -/
  seen : List (String × Nat) := []
  /-- What posse is connected to. -/
  network : String := ""
  deriving Inhabited

def help : String :=
  "/new NAME · /join NAME · /invite CODE · /remove WHO · /leave GROUP · /clear · /scan · /quit · Tab next group · F2 log · F10 blank"

def logRows : Nat := 6

/-- How posse's own notices are drawn; a message is never drawn so. -/
def noticeStyle : Style := { Style.fgOf .yellow with bold := true }

def current (u : Ui) : Option Chat := u.state.chats[u.selected]?

def hexByte (b : UInt8) : String :=
  let s := String.ofList (Nat.toDigits 16 b.toNat)
  if s.length < 2 then "0" ++ s else s

/-- The start of a member's key. -/
def fingerprint (key : ByteArray) : String := String.join ((key.extract 0 2).data.toList.map hexByte)

/-- The members whose names could be mistaken for another's, ours included, or that mix
scripts. -/
def doubtful (u : Ui) (c : Chat) : List ByteArray :=
  match c.group with
  | none => []
  | some g =>
    let named := g.readers.keys.map fun k => (k, skeleton ((c.names.get? k).getD "?"))
    let mine := skeleton u.state.me
    named.filterMap fun (k, sk) =>
      let name := (c.names.get? k).getD "?"
      if sk == mine || (named.filter (·.2 == sk)).length > 1 || mixedScript name then some k
      else none

/-- How a member is named: `me`, or the name they chose after `~`, with the start of their key
when it could be mistaken. -/
def who (u : Ui) (c : Chat) (key : ByteArray) : Shown :=
  if c.group.any (·.me == key) then ofApp "me"
  else
    let n := ofApp "~" ++ name ((c.names.get? key).getD "?")
    if (doubtful u c).contains key then n ++ ofApp s!" ({fingerprint key})" else n

/-- A conversation line as rows: each with a style, and a gutter on every row after the first. -/
def rows (u : Ui) (c : Chat) (l : Line) (width : Nat) : List (Style × String) :=
  let (style, head, body) :=
    if l.sender.size = 0 then (noticeStyle, ofApp "-- ", Display.body l.text)
    else
      let mine := c.group.any (·.me == l.sender)
      let mark := if !mine then "" else match l.status with
        | .pending => " ..."
        | .sent => if acknowledged c l then " ✓✓" else " ✓"
      let body := Display.body l.text
      let body := match body.getLast? with
        | some last => body.dropLast ++ [last ++ ofApp mark]
        | none => body
      ({}, who u c l.sender ++ ofApp ": ", body)
  let gutter := "  ┊ "
  let first := head.text
  let wrapped := body.zipIdx.flatMap fun (b, i) =>
    let lead := if i == 0 then first else gutter
    let parts := wrap (width - min width (stringWidth gutter)) b.text
    let parts := if parts.isEmpty then [""] else parts
    parts.zipIdx.map fun (p, j) => if j == 0 then lead ++ p else gutter ++ p
  -- A first row too wide for the pane wraps too, its rest under the gutter.
  wrapped.flatMap fun r =>
    match wrap width r with
    | [] => [(style, "")]
    | f :: rest => (style, f) :: rest.map fun p => (style, gutter ++ p)

/-- Rows, the last of them at the bottom unless scrolled back. -/
def bottomUp (make : Nat → List (Style × String)) (scroll : Nat) : Widget where
  hPolicy := .greedy
  vPolicy := .greedy
  render ctx :=
    let all := make ctx.width
    let offset := all.length - min all.length (ctx.height + scroll)
    (viewport offset (vBox (all.map fun (st, s) => withStyle st (str s)))).render ctx

def pickList (rows : List Shown) (selected : Nat) : Widget where
  hPolicy := .greedy
  vPolicy := .greedy
  render ctx :=
    let offset := selected + 1 - min (selected + 1) ctx.height
    let row (i : Nat) (s : Shown) :=
      if i == selected then vLimit 1 (withStyle { reverse := true } (hBox [str s.text, fill]))
      else str s.text
    (viewport offset (vBox (rows.zipIdx.map fun (s, i) => row i s))).render ctx

def unread (u : Ui) (c : Chat) : Nat := c.log.length - ((u.seen.lookup c.name).getD 0)

def groupRow (u : Ui) (c : Chat) : Shown :=
  let n := unread u c
  let state := if c.joining.isSome then " joining…" else if c.inducting.isSome then " adding…"
    else if c.group.isNone then " …" else ""
  name c.name ++ ofApp s!"{if n > 0 then s!" ({n})" else ""}{state}"

/-- Everyone who reads the group, ourselves first, each with the start of their key; a name that
could be mistaken is marked. -/
def members (u : Ui) (c : Chat) : List Shown :=
  match c.group with
  | none => []
  | some g =>
    let doubt := doubtful u c
    let others := g.readers.keys.map fun k => ((c.names.get? k).getD "?", k)
    let row (k : ByteArray) (n : Shown) :=
      n ++ ofApp s!" {fingerprint k}{if doubt.contains k then " (!)" else ""}"
    row g.me (ofApp "me") :: (others.mergeSort (fun a b => a.1 ≤ b.1)).map fun (n, k) =>
      row k (ofApp "~" ++ name n)

def status (u : Ui) : Shown :=
  let pending := u.state.chats.foldl (fun n c => n + c.jobs.length) 0
  let epoch := match (current u).bind (·.group) with
    | some g => s!"epoch {g.epoch} · "
    | none => ""
  ofApp s!" {epoch}{pending} to write · " ++ text u.network ++ ofApp " · " ++
    (if u.note.isEmpty then ofApp "F1 help" else text u.note)

def draw (u : Ui) : Widget :=
  if u.blank then center (str "posse · F10 to return") else
  let (title, conversation, who) := match current u with
    | some c => (ofApp " " ++ name c.name ++ ofApp " ",
                 fun w => c.log.flatMap (rows u c · w), members u c)
    | none => (ofApp " posse ",
               fun w => (["No groups yet.", "", help].flatMap (wrap w)).map ({}, ·), [])
  let target := match current u with
    | some c => ofApp " [" ++ name c.name ++ ofApp "] > "
    | none => ofApp " > "
  let top := hBox [
    hLimit 22 (borderWithLabel " groups " (pickList (u.state.chats.map (groupRow u)) u.selected)),
    borderWithLabel title.text (bottomUp conversation u.scroll),
    hLimit 26 (borderWithLabel " members " (vBox ((who.map (str ·.text)) ++ [fill])))]
  let log := if u.showLog then [vLimit (logRows + 2) (borderWithLabel " log (F2 hides) "
    (bottomUp (fun _ => u.logs.toList.map fun l => ({}, (text l).text)) 0))] else []
  vBox ([top] ++ log ++ [
    vLimit 3 (borderWithLabel " message, or /command " (hBox [
      withStyle (Style.fgOf .cyan) (str target.text), str (text u.input).text,
      withStyle { reverse := true } (str " "), fill])),
    withStyle { dim := true } (str (status u).text)])

/-- What a line typed asks for: a message for the core, a group to select, a note, and whether
to quit. -/
def command (u : Ui) (line : String) : Option Msg × Option String × String × Bool :=
  let words := (line.trimAscii.toString.splitOn " ").filter (· ≠ "")
  let rest := " ".intercalate (words.drop 1)
  let chat := (current u).map (·.name)
  let message : Option Msg × Option String × String × Bool := match chat with
    | some c => (some (.send c line), none, "", false)
    | none => (none, none, "create or join a group first: /new NAME or /join NAME", false)
  if u.pasted then message else
  match words.head? with
  | some "/quit" => (none, none, "", true)
  | some "/new" =>
    if rest.isEmpty then (none, none, "/new NAME", false) else (some (.create rest), some rest, "", false)
  | some "/join" =>
    if rest.isEmpty then (none, none, "/join NAME", false) else (some (.join rest), some rest, "", false)
  | some "/invite" =>
    match chat with
    | some c =>
      if rest.isEmpty then (none, none, "/invite CODE", false)
      else (some (.induct c rest), none,
        "whoever holds that code will read everything said in this group from now on", false)
    | none => (none, none, "select a group first", false)
  | some "/scan" => (chat.map .scan, none, "", false)
  | some "/clear" => (chat.map .clear, none, "", false)
  | some "/leave" =>
    match chat with
    | some c =>
      if rest == c then (some (.leave c), none, s!"left {c}", false)
      else (none, none, s!"to leave {c} and delete it here, type /leave {c}", false)
    | none => (none, none, "select a group first", false)
  | some "/remove" =>
    match chat with
    | some c =>
      if rest.isEmpty then (none, none, "/remove NAME, or the start of their key", false)
      else (some (.remove c rest), none, "", false)
    | none => (none, none, "select a group first", false)
  | some "/help" => (none, none, help, false)
  | some w =>
    if w.startsWith "/" then (none, none, s!"no such command: {w}", false)
    else message
  | none => (none, none, "", false)

/-- Count the selected conversation as read. -/
def markSeen (u : Ui) : Ui :=
  match current u with
  | some c => { u with seen := (c.name, c.log.length) :: u.seen.filter (·.1 != c.name) }
  | none => u

def select (u : Ui) (i : Nat) : Ui := markSeen { u with selected := i, scroll := 0 }

/-- A paste, without bracketed paste's markers, which would end it early. -/
def unmark (text : String) : String :=
  (text.replace "\x1b[200~" "").replace "\x1b[201~" ""

def edited (u : Ui) (input : String) : Ui :=
  { u with input, confirming := false, pasted := u.pasted && !input.isEmpty }

def update (send : Msg → IO Unit) : Tessera.Msg Event → Ui → IO (Ui × Bool)
  | .custom (.state s), u =>
    let selected := match u.want with
      | some w => (s.chats.findIdx? (·.name == w)).getD u.selected
      | none => u.selected
    let want := u.want.filter fun w => !s.chats.any (·.name == w)
    pure (markSeen { u with state := s, selected := min selected (s.chats.length - 1), want }, false)
  | .custom (.logs lines), u => pure ({ u with logs := lines }, false)
  | .input (.key (.f 10) _), u => pure ({ u with blank := !u.blank }, false)
  | _, u@{ blank := true, .. } => pure (u, false)
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
  | .input (.key .backspace _), u => pure (edited u (u.input.dropEnd 1).toString, false)
  | .input (.key .enter _), u => do
    let lines := (u.input.splitOn "\n").length
    if lines > 1 && !u.confirming && (current u).isSome then
      let to := (current u).map (·.name) |>.getD ""
      return ({ u with confirming := true,
                       note := s!"that is {lines} lines to {to}: Enter again sends them" }, false)
    let (m, want, note, quit) := command u u.input
    if let some m := m then send m
    pure ({ u with input := "", pasted := false, confirming := false,
                   want := want.orElse fun _ => u.want, note, scroll := 0 }, quit)
  | .input (.key (.char c) m), u =>
    if m.ctrl || m.alt then pure (u, false) else pure (edited u (u.input.push c), false)
  | .input (.paste text), u =>
    let first := u.input.isEmpty
    let u := edited u (u.input ++ (unmark text).trimAscii.toString)
    pure ({ u with pasted := u.pasted || first }, false)
  | _, u => pure (u, false)

end Posse.Ui
