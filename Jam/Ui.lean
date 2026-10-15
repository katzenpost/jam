/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Tessera
import GroupChatClient.Shell
import GroupChatClient.GroupChatKatzenqt1.Core
import Jam.Display
import Jam.Theme

/-! # The terminal UI

A bar across the top names jam, the selected group, its members and epoch, and the network. Below
it, the groups on the left, the selected conversation in the middle, and on the right everyone who
reads what is written there, each with the start of their key, since a display name is only what
its owner chose. Below, the log, which F2 hides, then the line to type into, which names the group
it goes to, and a bar of keys. A line typed beginning with `/` is a command; F1 shows them all.

jam, not the sender, decides what each part of the screen says, as Yee's trusted path asks:

- Everything drawn is a Tessera `Text`: jam's own words are checked literals, and text from the
  network has been filtered on its way (`Jam.Display`).
- jam's own words are drawn in styles no member's text can have (`Jam.Theme`): a member's name is
  in a colour picked from their key, a basic one, and jam's notices, `me`, the frame and the bars
  in reserved ones.
- A member's own name is shown after `~`, as a name they chose; ours as `me`, which no member can
  take, since theirs always begins with `~`. A name that looks like another member's, or ours, or
  mixes scripts, also shows the start of its key.
- A message's name has a column of its own, and every row of the message after its first begins
  with a gutter in its sender's colour, so a newline or a wrap cannot start a row that passes for
  another message.
- jam's own notices begin with `--`, in their own style.
- Pasting into an empty line types a message, never a command, and a message of several lines is
  sent only on a second Enter, after jam has said how many lines it is. -/

namespace Jam.Ui

open Tessera Widget
open Jam.Display
open Tessera.Untrusted (Ident)
open Tessera.Untrusted.Ident (skeleton mixedScript)
open CryptWalker.Protocols.GroupComm.Common
open CryptWalker.Protocols.GroupComm.GroupChatKatzenqt1.Member
open GroupChatClient GroupChatClient.GroupChatKatzenqt1

abbrev W := Widget CS .remote

inductive Event
  | state (s : State)
  | logs (lines : Array String)

structure Ui where
  state : State
  selected : Nat := 0
  input : Input CS := {}
  /-- What was pasted, as it was, when it is more than one line: it is sent whole. -/
  pastedLines : Option String := none
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
  /-- The commands and keys, shown over the panes. -/
  help : Bool := false
  /-- The screen blanked, for someone looking over your shoulder. -/
  blank : Bool := false
  /-- Whether the window has the focus. -/
  focused : Bool := true
  /-- The screen's size, for telling where the mouse is. -/
  screen : Nat × Nat := (100, 30)
  /-- How many lines of each conversation have been shown. -/
  seen : List (String × Nat) := []
  /-- What jam is connected to. -/
  network : String := ""
  deriving Inhabited

/-! ## Layout -/

def groupsWidth : Nat := 22
def membersWidth : Nat := 26
def logRows : Nat := 6

/-- Rows of the screen above the panes, and below them, without the log. -/
def headerRows : Nat := 1
def inputRows : Nat := 3
def statusRows : Nat := 1

/-- How many rows the panes at the top take on a screen `h` rows high. -/
def topRows (u : Ui) (h : Nat) : Nat :=
  h - min h (headerRows + inputRows + statusRows + if u.showLog then logRows + 2 else 0)

def current (u : Ui) : Option Chat := u.state.chats[u.selected]?

/-! ## Commands -/

/-- jam's commands: the word, what follows it, and what it does. -/
def commands : List (String × String × String) :=
  [("/new", "NAME", "start a group of your own"),
   ("/join", "NAME", "join someone else's group, called NAME here"),
   ("/invite", "CODE", "let in the person whose voucher code you were given"),
   ("/remove", "WHO", "stop reading a member, by name or start of key"),
   ("/leave", "GROUP", "leave the selected group and delete it here"),
   ("/clear", "", "delete this conversation's lines here"),
   ("/scan", "", "look again for messages a stream skipped"),
   ("/help", "", "show the commands and keys"),
   ("/quit", "", "quit")]

/-- The keys, and what they do. -/
def keys : List (String × String) :=
  [("Tab, Shift-Tab", "the next or previous group; Tab completes a /command"),
   ("PgUp, PgDn, wheel", "scroll the conversation"),
   ("Up, Down", "the lines sent before"),
   ("Ctrl-A, Ctrl-E, Ctrl-W, Ctrl-U", "start, end, delete a word, delete to the start"),
   ("click", "select a group"),
   ("F1", "this help"),
   ("F2", "hide or show the log"),
   ("F10", "blank the screen at once, and bring it back"),
   ("Esc, Ctrl-C", "close this help, drop a paste, or quit")]

/-- The commands the word `w` could be the start of. -/
def matching (w : String) : List (String × String × String) :=
  commands.filter fun (c, _, _) => c.startsWith w

/-! ## Words -/

/-- jam's own words, made at run time from ASCII: numbers, keys, fingerprints. -/
def ascii (s : String) : Text CS .app := (Text.ofAscii? s).getD .empty

/-- jam's own words where text from the network may also be. -/
def lit (t : Text CS .app) : Shown := t.lift

def spaces (n : Nat) : Text CS .app := ascii (String.ofList (List.replicate n ' '))

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
    let named := g.readers.keys.map fun k => (k, name ((c.names.get? k).getD "?"))
    let mine := skeleton (name u.state.me)
    named.filterMap fun (k, n) =>
      let sk := skeleton n
      if sk == mine || (named.filter fun (_, m) => skeleton m == sk).length > 1 || mixedScript n
      then some k else none

/-- How a member is named: the name they chose after `~`, with the start of their key when it
could be mistaken. -/
def who (u : Ui) (c : Chat) (key : ByteArray) : Shown :=
  let n := lit t!"~" ++ (name ((c.names.get? key).getD "?")).text
  if (doubtful u c).contains key then n ++ (t!" " ++ ascii (fingerprint key)).lift else n

/-! ## Rows -/

/-- Text in a style. -/
structure Seg where
  style : Style
  text : Shown

def seg (style : Style) (t : Text CS .app) : Seg := ⟨style, t.lift⟩

/-- A row of styled text, the rest of the row left blank. -/
def row (ss : List Seg) : W := vLimit 1 (hBox ((ss.map fun s => withStyle s.style (str s.text)) ++ [fill]))

/-- Rows, the last of them at the bottom unless scrolled back. -/
def bottomUp (make : Nat → List (List Seg)) (scroll : Nat) : W :=
  Widget.custom (hPolicy := .greedy) (vPolicy := .greedy) fun ctx =>
    let all := make ctx.width
    let offset := all.length - min all.length (ctx.height + scroll)
    (viewport offset (vBox (all.map row))).render ctx

/-- `t` cut into rows `width` cells wide, at least one. -/
def wrapped (t : Shown) (width : Nat) : List Shown :=
  match t.wrap (max width 2) with
  | [] => [.empty]
  | ls => ls.map (·.text)

/-- How wide the column of names is in a conversation. -/
def labelWidth (u : Ui) (c : Chat) : Nat :=
  let ws := c.log.filterMap fun l =>
    if l.sender.size = 0 then none
    else if c.group.any (·.me == l.sender) then some 2
    else some (who u c l.sender).width
  min 20 (ws.foldl max 2)

/-- A conversation line as rows: a notice in jam's style; a message with its sender's name in a
column of its own, and a gutter in their colour on every row after the first. -/
def lineRows (u : Ui) (c : Chat) (l : Line) (width labelW : Nat) : List (List Seg) :=
  if l.sender.size = 0 then
    (wrapped (lit t!"-- " ++ text l.text) width).map fun r => [⟨Theme.notice, r⟩]
  else
    let mine := c.group.any (·.me == l.sender)
    let (style, label) : Style × Shown :=
      if mine then (Theme.me, (t!"me" : Text CS .app).lift)
      else ((Theme.member l.sender).toStyle, (who u c l.sender).truncate labelW)
    let colour := if mine then Theme.me else (Theme.member l.sender).toStyle
    let bodyWidth := width - min width (labelW + 3)
    let pieces := (body l.text).flatMap (wrapped · bodyWidth)
    let mark : List Seg := if !mine then [] else match l.status with
      | .pending => [seg Theme.pending t!" …"]
      | .sent => if acknowledged c l then [seg Theme.acknowledged t!" √√"] else [seg Theme.sent t!" √"]
    let n := pieces.length
    pieces.zipIdx.map fun (p, i) =>
      let lead := if i == 0 then [⟨style, label⟩, seg {} (spaces (labelW - label.width + 3))]
        else [seg {} (spaces labelW), seg colour t!" ┊ "]
      lead ++ [⟨{}, p⟩] ++ (if i + 1 == n then mark else [])

/-! ## Panes -/

/-- `w` in a frame with round corners and `label` in its top edge: in jam's accent when it is the
pane being used. -/
def panel (label : Shown) (focused : Bool) (w : W) : W :=
  Widget.custom (hPolicy := w.hPolicy) (vPolicy := w.vPolicy) fun ctx =>
    if hs : ctx.width < 2 ∨ ctx.height < 2 then .empty
    else
      let inner := w.render { ctx with width := ctx.width - 2, height := ctx.height - 2 }
      have hw : inner.w ≤ ctx.width - 2 := inner.w_le
      have hh : inner.h ≤ ctx.height - 2 := inner.h_le
      let bw := inner.w + 2
      let bh := inner.h + 2
      let frame := if focused then Theme.accent else Theme.frame
      let put (b : Buffer CS bw bh) (x y : Nat) (t : Text CS .app) (s : Style) :=
        (b.putString x y t.glyphs s).1
      let line := ascii "" ++ (Text.ofLit (String.ofList (List.replicate inner.w '─')) (by
        intro c hc; simp at hc; rw [hc.2]; decide) : Text CS .app)
      let b := Buffer.blank (cs := CS) bw bh
      let b := put b 0 0 (t!"╭" ++ line ++ t!"╮") frame
      let b := put b 0 (bh - 1) (t!"╰" ++ line ++ t!"╯") frame
      let b := (List.range inner.h).foldl (init := b) fun b y =>
        put (put b 0 (y + 1) t!"│" frame) (bw - 1) (y + 1) t!"│" frame
      let b := if inner.w ≥ 4 then
          (b.putString 1 0 (lit t!" " ++ label.truncate (inner.w - 2) ++ lit t!" ").glyphs
            (if focused then Theme.label else Theme.frame)).1
        else b
      ⟨bw, bh, by omega, by omega, b.blit 1 1 inner.buf⟩

def unread (u : Ui) (c : Chat) : Nat := c.log.length - ((u.seen.lookup c.name).getD 0)

def groupRow (u : Ui) (c : Chat) : W :=
  let n := unread u c
  let state := if c.joining.isSome then t!" joining…" else if c.inducting.isSome then t!" adding…"
    else if c.group.isNone then t!" …" else .empty
  hBox [withStyle { bold := true } (str (text c.name)), fill,
    withStyle Theme.quiet (str state),
    if n > 0 then withStyle Theme.unread (str (t!" " ++ .ofNat n ++ t!" ")) else .empty]

def groups (u : Ui) : W :=
  ({ items := u.state.chats.toArray, selected := u.selected } : ListView Chat).view (groupRow u)

/-- Everyone who reads the group, ourselves first, each with the start of their key; a name that
could be mistaken is marked. -/
def members (u : Ui) (c : Chat) : W :=
  match c.group with
  | none => vBox [withStyle Theme.quiet (txt t!"not in the group yet"), fill]
  | some g =>
    let doubt := doubtful u c
    let others := g.readers.keys.map fun k => ((c.names.get? k).getD "?", k)
    let keyOf (k : ByteArray) := withStyle Theme.key (str (t!" " ++ ascii (fingerprint k)))
    let mine := vLimit 1 (hBox [withStyle Theme.me (str t!"me"), fill, keyOf g.me])
    let rows := (others.mergeSort (fun a b => a.1 ≤ b.1)).map fun (n, k) =>
      vLimit 1 <| hBox [withSenderStyle (Theme.member k) (str (lit t!"~" ++ (name n).text)),
        fill, if doubt.contains k then withStyle Theme.warning (str t!" (!)") else .empty, keyOf k]
    vBox (mine :: rows ++ [fill])

/-- The banner shown before there is a group. -/
def banner : List (Text CS .app) :=
  [t!"     ╦ ╔═╗ ╔╦╗", t!"     ║ ╠═╣ ║║║", t!"   ╚═╝ ╩ ╩ ╩ ╩"]

def welcome : W :=
  center (hLimit 56 (vBox (banner.zipIdx.map (fun (l, i) => withStyle (Theme.banner i) (str l)) ++
    [str t!"",
     withStyle Theme.label (str t!"group chat over the Katzenpost mixnet"),
     str t!"",
     table [.fit, .fit] [t!"to", t!"type"]
       [[t!"start a group of your own", t!"/new NAME"],
        [t!"join someone else's group", t!"/join NAME"],
        [t!"let someone into yours", t!"/invite CODE"]],
     str t!"",
     withStyle Theme.quiet (str t!"F1 shows every command and key")])))

def helpPanel : W :=
  hLimit 78 (vLimit 24 (panel (t!"help · F1 or Esc closes" : Text CS .app).lift true (vBox [
    table [.fit, .fit, .ratio 1] [t!"command", t!"", t!"does"]
      (commands.map fun (c, a, d) => [ascii c, ascii a, ascii d]),
    str t!"",
    table [.fit, .ratio 1] [t!"key", t!"does"] (keys.map fun (k, d) => [ascii k, ascii d]),
    fill])))

def conversation (u : Ui) (c : Chat) : W :=
  let lines := bottomUp (fun w =>
    let lw := labelWidth u c
    c.log.flatMap fun l => lineRows u c l w lw) u.scroll
  match c.joining with
  | some (.awaiting code ..) =>
    -- The code to hand a member, where it cannot be missed; it is also in a file to copy.
    vBox [vLimit 1 (hBox [withStyle Theme.toast (str (lit t!" voucher code " ++ text code ++ lit t!" ")),
            withStyle Theme.quiet (str (lit t!" also in " ++ text (voucherFile c.name))), fill]),
          lines]
  | _ => lines

def logPane (u : Ui) : W :=
  bottomUp (fun w => u.logs.toList.flatMap fun l =>
    let tag := ((l.splitOn " ").drop 1).headD ""
    (wrapped (text l) w).map fun r => [⟨Theme.logLevel tag, r⟩]) 0

/-! ## Bars -/

def header (u : Ui) : W :=
  let shade (i : Nat) := if u.focused then Theme.header i else Theme.header 4
  let part (i : Nat) (t : Shown) := withStyle (shade i) (str (lit t!" " ++ t ++ lit t!" "))
  let about : List W := match current u with
    | some c =>
      let about : Text CS .app := match c.group with
        | some g =>
          let n := g.readers.keys.length + 1
          Text.ofNat n ++ (if n == 1 then t!" member" else t!" members") ++ t!" · epoch " ++ .ofNat g.epoch
        | none => t!"not joined yet"
      [part 1 (text c.name), part 2 about.lift]
    | none => [part 1 (t!"no group yet" : Text CS .app).lift]
  vLimit 1 <| hBox ([part 0 (t!"≋ jam" : Text CS .app).lift] ++ about ++
    [withStyle (shade 3) fill, part 2 (text u.network)])

/-- The hint for the line being typed: the commands it could be. -/
def hint (u : Ui) : Option Shown :=
  let typed := u.input.text.text
  if !typed.startsWith "/" || typed.any (· == ' ') then none
  else match matching typed with
    | [] => some (t!"no such command" : Text CS .app).lift
    | [(c, a, d)] => some (ascii s!"{c} {a}" ++ t!" · " ++ ascii d).lift
    | ms => some (ascii (" ".intercalate (ms.map (·.1)))).lift

def statusBar (u : Ui) : W :=
  let key (k d : Text CS .app) : List W :=
    [withStyle Theme.statusKey (str (t!" " ++ k ++ t!" ")), withStyle Theme.status (str (t!" " ++ d ++ t!" "))]
  let keysShown : List W :=
    if u.pastedLines.isSome then key t!"Enter" t!"sends" ++ key t!"Esc" t!"drops"
    else if u.confirming then key t!"Enter" t!"sends them" ++ key t!"Esc" t!"drops"
    else match hint u with
      | some h => [withStyle Theme.status (str (lit t!" " ++ h ++ lit t!" ")), withStyle Theme.statusKey (str t!" Tab ")]
      | none => key t!"F1" t!"help" ++ key t!"Tab" t!"groups" ++ key t!"PgUp" t!"scroll" ++
          key t!"F2" t!"log" ++ key t!"F10" t!"hide"
  let pending := u.state.chats.foldl (fun n c => n + c.jobs.length) 0
  let note : List W := if u.note.isEmpty then [] else [withStyle Theme.toast (str (lit t!" " ++ text u.note ++ lit t!" "))]
  vLimit 1 <| hBox (keysShown ++ [withStyle Theme.status fill] ++ note ++
    [withStyle Theme.status (str (t!" " ++ .ofNat pending ++ t!" to write "))])

def inputBox (u : Ui) : W :=
  let target : Shown := match current u with
    | some c => (t!"[" : Text CS .app).lift ++ text c.name ++ (t!"]" : Text CS .app).lift
    | none => (t!"message, or /command" : Text CS .app).lift
  let field : W := match u.pastedLines with
    | some p =>
      withStyle Theme.toast (str (t!" ≡ " ++ .ofNat (p.splitOn "\n").length ++ t!" lines pasted · Enter sends · Esc drops "))
    | none => u.input.view u.focused
  panel target true (hBox [withStyle Theme.accent (str t!"› "), field])

def draw (u : Ui) : W :=
  if u.blank then center (withStyle Theme.quiet (str t!"jam · F10 to return")) else
  let top : W :=
    if u.help then center helpPanel
    else match current u with
      | none => panel (t!"jam" : Text CS .app).lift true welcome
      | some c => hBox [
          hLimit groupsWidth (panel (t!"groups" : Text CS .app).lift false (groups u)),
          panel (text c.name) true (conversation u c),
          hLimit membersWidth (panel (t!"members" : Text CS .app).lift false (members u c))]
  let log := if u.showLog then
      [vLimit (logRows + 2) (panel (t!"log · F2 hides" : Text CS .app).lift false (logPane u))]
    else []
  vBox ([header u, top] ++ log ++ [vLimit inputRows (inputBox u), statusBar u])

/-! ## Input -/

/-- The members of `c` that `who` names: by display name, or by the start of the key in hex. -/
def named (c : Chat) (who : String) : List ByteArray :=
  match c.group with
  | none => []
  | some g =>
    let byName := g.readers.keys.filter fun k => c.names.get? k == some who
    if byName.isEmpty && who.length ≥ 4 then
      g.readers.keys.filter fun k => (hex k).startsWith who.toLower
    else byName

/-- What a line typed asks for: a message for the core, a group to select, a note, and whether
to quit. -/
def command (u : Ui) (line : String) : Option Msg × Option String × String × Bool :=
  let words := (line.trimAscii.toString.splitOn " ").filter (· ≠ "")
  let taken (name : String) := u.state.chats.any (·.name == name)
  let rest := " ".intercalate (words.drop 1)
  let chat := (current u).map (·.name)
  let message : Option Msg × Option String × String × Bool := match chat with
    | some c => (some (.send c line), none, "", false)
    | none => (none, none, "create or join a group first: /new NAME or /join NAME", false)
  if u.pasted then message else
  match words.head? with
  | some "/quit" => (none, none, "", true)
  | some "/new" =>
    if rest.isEmpty then (none, none, "/new NAME starts a group of your own", false)
    else if taken rest then (none, some rest, s!"you already have a group called {rest}", false)
    else (some (.create rest), some rest, "", false)
  | some "/join" =>
    if rest.isEmpty then
      (none, none, "/join NAME joins someone else's group: NAME is what you will call it here", false)
    else if taken rest then
      (none, some rest, s!"you already have a group called {rest}: /join is for someone else's group, under a name of its own", false)
    else (some (.join rest), some rest,
      "a voucher code will appear: give it to a member of the group, who types /invite CODE", false)
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
      else match (current u).map (named · rest) with
        | some [k] => (some (.remove c k), none, "", false)
        | some (_ :: _ :: _) =>
          (none, none, s!"more than one member is called {rest}: name them by the start of their key", false)
        | _ => (none, none, s!"no member is called {rest}", false)
    | none => (none, none, "select a group first", false)
  | some "/help" => (none, none, "", false)
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

def nextGroup (u : Ui) (back : Bool) : Ui :=
  let n := u.state.chats.length
  if n = 0 then u else select u (if back then (u.selected + n - 1) % n else (u.selected + 1) % n)

/-- The line typed so far, completed to the one command it could be. -/
def complete (u : Ui) : Option Ui :=
  let typed := u.input.text.text
  if !typed.startsWith "/" || typed.any (· == ' ') then none
  else match matching typed with
    | [(c, _, _)] =>
      some { u with input := { Input.ofText (text (c ++ " ")) with history := u.input.history } }
    | _ => none

/-- Send what was typed or pasted. -/
def enter (send : Msg → IO Unit) (u : Ui) : IO (Ui × Bool) := do
  let line := match u.pastedLines with
    | some p => u.input.text.text ++ p
    | none => u.input.text.text
  let lines := (line.splitOn "\n").length
  if lines > 1 && !u.confirming && (current u).isSome then
    let to := (current u).map (·.name) |>.getD ""
    return ({ u with confirming := true,
                     note := s!"that is {lines} lines to {to}: Enter again sends them" }, false)
  if line.trimAscii.isEmpty then return (u, false)
  if line.trimAscii.toString == "/help" && !u.pasted then
    return ({ u with help := true, input := (u.input.submit).1 }, false)
  let (m, want, note, quit) := command u line
  if let some m := m then send m
  pure ({ u with input := (u.input.submit).1, pastedLines := none, pasted := false,
                 confirming := false, want := want.orElse fun _ => u.want, note, scroll := 0 }, quit)

/-- Where the mouse is: the row of the groups list it is on, or the conversation. -/
inductive Place
  | group (row : Nat)
  | conversation
  | elsewhere

def place (u : Ui) (column row : Nat) : Place :=
  let top := topRows u u.screen.2
  if row < headerRows + 1 || row + 1 ≥ headerRows + top then .elsewhere
  else if column < groupsWidth then .group (row - headerRows - 1)
  else if column + membersWidth < u.screen.1 then .conversation
  else .elsewhere

def update (send : Msg → IO Unit) : Tessera.Msg Event → Ui → IO (Ui × Bool)
  | .custom (.state s), u =>
    let selected := match u.want with
      | some w => (s.chats.findIdx? (·.name == w)).getD u.selected
      | none => u.selected
    let want := u.want.filter fun w => !s.chats.any (·.name == w)
    pure (markSeen { u with state := s, selected := min selected (s.chats.length - 1), want }, false)
  | .custom (.logs lines), u => pure ({ u with logs := lines }, false)
  | .resize w h, u => pure ({ u with screen := (w, h) }, false)
  | .focus gained, u => pure ({ u with focused := gained }, false)
  | .key (.f 10) _ _, u => pure ({ u with blank := !u.blank }, false)
  | _, u@{ blank := true, .. } => pure (u, false)
  | .key (.char 'c') { ctrl := true, .. } _, u => pure (u, true)
  | .key .esc _ _, u =>
    if u.help then pure ({ u with help := false }, false)
    else if u.pastedLines.isSome || u.confirming then
      pure ({ u with pastedLines := none, confirming := false, pasted := false, note := "" }, false)
    else pure (u, true)
  | .key (.f 1) _ _, u => pure ({ u with help := !u.help }, false)
  | _, u@{ help := true, .. } => pure (u, false)
  | .key (.f 2) _ _, u => pure ({ u with showLog := !u.showLog }, false)
  | .key .tab _ _, u => pure ((complete u).getD (nextGroup u false), false)
  | .key .backTab _ _, u => pure (nextGroup u true, false)
  | .key .pageUp _ _, u => pure ({ u with scroll := u.scroll + 10 }, false)
  | .key .pageDown _ _, u => pure ({ u with scroll := u.scroll - 10 }, false)
  | .key .enter _ _, u => enter send u
  | .mouse { kind := .down .left, column, row, .. } _, u =>
    match place u column row with
    | .group r =>
      let l : ListView Chat := { items := u.state.chats.toArray, selected := u.selected }
      let l := l.click r (topRows u u.screen.2 - 2)
      pure (if l.selected == u.selected then u else select u l.selected, false)
    | _ => pure (u, false)
  | .mouse { kind := .scrollUp, column, row, .. } _, u =>
    match place u column row with
    | .group _ => pure (nextGroup u true, false)
    | _ => pure ({ u with scroll := u.scroll + 3 }, false)
  | .mouse { kind := .scrollDown, column, row, .. } _, u =>
    match place u column row with
    | .group _ => pure (nextGroup u false, false)
    | _ => pure ({ u with scroll := u.scroll - 3 }, false)
  | .paste p u', u =>
    let first := u.input.length == 0 && u.pastedLines.isNone
    let lines := p.text.trimAscii.toString
    if (lines.splitOn "\n").length > 1 || u.pastedLines.isSome then
      let before := (u.pastedLines.map (· ++ "\n")).getD u.input.text.text
      pure ({ u with pastedLines := some (before ++ lines), input := { history := u.input.history },
                     pasted := u.pasted || first, confirming := false }, false)
    else
      let (input, _) := u.input.update (ε := Event) (.paste p u')
      pure ({ u with input, pasted := u.pasted || first, confirming := false }, false)
  | m, u =>
    let (input, _) := u.input.update m
    let changed := input.text.text != u.input.text.text
    pure ({ u with input, confirming := u.confirming && !changed,
                   pasted := u.pasted && input.length > 0 }, false)

end Jam.Ui
