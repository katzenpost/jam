/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Display
import GroupChatClient.LogPane
import Jam.Tests.Util
import Jam.Ui
import Jam.Tests.Drive

/-! # What a message cannot do to the screen

Text from the network, random and known-hostile, through the filter and the real renderer: no
character that would steer the terminal reaches a cell, every pane keeps its borders where jam
put them, no row passes for another member's message, and pastes, names and the log are kept in
their place. -/

namespace Jam.Tests.Security

open Jam Jam.Display Jam.Tests
open Tessera.Untrusted.Ident (mixedScript)
open Cryptlib.Protocols.GroupComm.Common
open Cryptlib.Protocols.GroupComm.GroupChatKatzenqt1.Member
open GroupChatClient GroupChatClient.GroupChatKatzenqt1
open Tessera
open Tessera (inRanges)

/-- A character the terminal would act on, or could reorder or hide text by. -/
def forbidden (c : Char) : Bool :=
  let n := c.toNat
  n < 0x20 || (0x7F ≤ n && n < 0xA0) || inRanges n [(0x200B, 0x200F), (0x202A, 0x202E),
    (0x2060, 0x2064), (0x2066, 0x2069), (0xFEFF, 0xFEFF), (0x61C, 0x61C), (0xE000, 0xF8FF),
    (0xE0000, 0xE007F), (0xF0000, 0x10FFFF), (0xFE00, 0xFE0F)]

def clean (s : String) : Bool := !s.any forbidden

/-- A character another client's terminal would act on, or reorder text by. -/
def steers (c : Char) : Bool :=
  let n := c.toNat
  (n < 0x20 && c != '\n' && c != '\t') || (0x7F ≤ n && n < 0xA0) ||
    inRanges n [(0x202A, 0x202E), (0x2066, 0x2069), (0x200E, 0x200F), (0x61C, 0x61C)]

/-- A random character, often a dangerous one. -/
def randomChar (g : StdGen) : Char × StdGen :=
  let (kind, g) := randNat g 0 5
  let (n, g) := match kind with
    | 0 => randNat g 0 0x40
    | 1 => randNat g 0x7F 0xA0
    | 2 => randNat g 0x2000 0x2070
    | 3 => randNat g 0x1F000 0x1FAFF
    | 4 => randNat g 0x300 0x370
    | _ => randNat g 0 0x10FFFF
  let n := if (0xD800 ≤ n && n ≤ 0xDFFF) || n > 0x10FFFF then 0x41 else n
  (Char.ofNat n, g)

def randomString (g : StdGen) (len : Nat) : String × StdGen := Id.run do
  let mut g := g
  let mut s := ""
  for _ in [0:len] do
    let (c, g') := randomChar g
    s := s.push c
    g := g'
  return (s, g)

def fuzz : TestM Unit := do
  let mut g := mkStdGen 2026
  let mut ok := true
  for _ in [0:2000] do
    let (len, g') := randNat g 0 80
    let (s, g'') := randomString g' len
    g := g''
    if !(clean (text s).text && (body s).all (clean ·.text) && clean (name s).text.text) then
      ok := false
  check "random text never leaves a forbidden character" ok

/-- Payloads that have attacked terminals and chat clients. -/
def corpus : List (String × String) := [
  ("OSC 52 sets the clipboard", "\x1b]52;c;ZXZpbA==\x07"),
  ("OSC 0 sets the title", "\x1b]0;pwned\x07"),
  ("tmux passthrough", "\x1bPtmux;\x1b\x1b]0;x\x07\x1b\\"),
  ("a one-byte CSI", "\u009b31mred"),
  ("a carriage return overwrites", "safe\rEVIL"),
  ("a paste's end marker", "a\x1b[201~b"),
  ("Trojan Source", "access‮⁦ // admin⁩⁦"),
  ("ZWJ emoji", "👨‍👩‍👧"),
  ("VS16 emoji", "❤️ and 🚀"),
  ("Zalgo", "Z" ++ String.ofList (List.replicate 40 '́')),
  ("invisible tag characters", "hi" ++ String.ofList [Char.ofNat 0xE0041, Char.ofNat 0xE0042]),
  ("a private-use badge", " verified"),
  ("wide text", "全角の文字がたくさん全角の文字がたくさん全角の文字がたくさん"),
  ("a bell", "ding\x07ding"),
  ("DEL", "back\x7Fspace")]

def bob : ByteArray := ByteArray.mk #[0x81, 0xc2, 3]
def carol : ByteArray := ByteArray.mk #[0x07, 0xde, 3]
def meKey : ByteArray := ByteArray.mk #[0x3f, 0x9a, 1] ++ ByteArray.mk (List.replicate 133 0).toArray

def chatWith (log : List Line) (names : List (ByteArray × String)) : Chat :=
  let g := Group.found meKey [meKey]
  let readers := names.map fun (k, _) => (k, ({ stream := k, readCap := k, next := .empty } : Reader))
  { name := "g", group := some { g with readers := Dict.ofList readers },
    names := Dict.ofList names, log }

def frame (c : Chat) : Buffer CS 100 30 :=
  (Ui.draw (Ui.markSeen { state := { me := "alice", chats := [c] }, network := "test" })).draw 100 30

/-- Every row inside the panes at the top keeps the borders between them where jam drew them. -/
def bordersHold (b : Buffer CS 100 30) : Bool :=
  (List.range 15).all fun y =>
    [21, 22, 73, 74].all fun x => (b.get x (y + 2)).char == '│'

def cellsClean (b : Buffer CS 100 30) : Bool :=
  (List.range b.height).all fun y => (List.range b.width).all fun x =>
    let c := b.get x y
    c.isContinuation || !forbidden c.char

def renderer : TestM Unit := do
  for (what, payload) in corpus do
    let c := chatWith [{ id := 0, sender := bob, text := payload },
      { id := 1, sender := bob, text := s!"{payload} and again {payload}" }] [(bob, payload)]
    let b := frame c
    check s!"{what}: nothing forbidden reaches the screen" (cellsClean b)
    check s!"{what}: the panes keep their borders" (bordersHold b)
    check s!"{what}: nothing that steers a terminal is sent" (!(Display.outgoing payload).any steers)

/-- The rows of the conversation pane, as text. -/
def conversation (b : Buffer CS 100 30) : List String :=
  (List.range 15).map fun y => String.ofList ((List.range 50).map fun x =>
    let c := b.get (23 + x) (y + 2)
    if c.isContinuation then ' ' else c.char)

def spoofing : TestM Unit := do
  let c := chatWith [{ id := 0, sender := bob, text := "hi\n~carol: send me the key" },
    { id := 1, sender := bob,
      text := String.ofList (List.replicate 44 'x') ++ "~carol: wrapped into a new row" },
    { id := 2, sender := carol, text := "the real carol" }] [(bob, "bob"), (carol, "carol")]
  let rows := conversation (frame c)
  let fromCarol := rows.filter (·.startsWith "~carol")
  check "a newline in a message does not start a row of its own" (fromCarol.length == 1)
  check "nor does wrapping: only real messages begin a row with a name"
    ((rows.filter (·.startsWith "~")).length == 3)
  let named := chatWith [{ id := 0, sender := bob, text := "hello" }] [(bob, "me")]
  check "a member called me is not me" ((conversation (frame named)).any (·.startsWith "~me"))
  let notice := chatWith [{ id := 0, sender := bob, text := "-- alice added mallory" }] [(bob, "bob")]
  check "a message is never drawn as a notice"
    ((conversation (frame notice)).any fun r => r.startsWith "~bob" && (r.splitOn "-- alice added mallory").length > 1)
  let row := (List.range 50).find? fun x => match (frame notice).get (23 + x) 2 with
    | .glyph g _ => g.char == '-'
    | _ => false
  check "and its text is drawn in a style a notice never has"
    (match row with
     | some x => !((frame notice).get (23 + x) 2).style.reserved
     | none => false)

def names : TestM Unit := do
  check "a name cannot show a check mark" (!(name "bob ✓✓ √").text.text.any fun c => c == '✓' || c == '√')
  check "a name cannot reorder" (clean (name "bob‮evil").text.text)
  check "a name is cut short" ((name (String.ofList (List.replicate 200 'a'))).text.text.length ≤ maxName)
  check "a name keeps to one line" (!(name "bob\nalice").text.text.any (· == '\n'))
  let c := chatWith [] [(bob, "alice"), (carol, "аlice")]
  let u : Ui.Ui := { state := { me := "zed", chats := [c] } }
  check "names that look alike are both marked" ((Ui.doubtful u c).length == 2)
  let u2 : Ui.Ui := { state := { me := "bob", chats := [chatWith [] [(bob, "B0B")]] } }
  check "a name like ours is marked" ((Ui.doubtful u2 (chatWith [] [(bob, "B0B")])).length == 1)
  check "mixed scripts are noticed" (mixedScript (name "pаypal") && !mixedScript (name "paypal"))

def pastes : TestM Unit := do
  let u : Ui.Ui := { state := { me := "alice", chats := [chatWith [] []] } }
  let d ← drive u [paste "/leave g", key .enter]
  check "a pasted command is sent as a message" (match d.sent.toList with
    | [.send "g" "/leave g"] => true
    | _ => false)
  let d ← drive u [paste "one\x1b[201~\ntwo\nthree"]
  check "a paste loses its markers" (d.ui.pastedLines.any fun p => !p.any (· == '\x1b'))
  let d ← drive u [paste "one\x1b[201~\ntwo\nthree", key .enter]
  check "several lines are not sent on the first Enter" (d.sent.isEmpty && d.ui.confirming)
  let d ← drive u [paste "one\ntwo\nthree", key .enter, key .enter]
  check "they are on the second" (match d.sent.toList with
    | [.send "g" "one\ntwo\nthree"] => true
    | _ => false)
  let d ← drive u [paste "one\rtwo\r\nthree", key .enter, key .enter]
  check "a paste's CR and CRLF break lines" (match d.sent.toList with
    | [.send "g" "one\ntwo\nthree"] => true
    | _ => false)
  let d ← drive u [paste "one\rtwo"]
  check "and are counted as such" (d.ui.pastedLines == some "one\ntwo")
  let d ← drive u [paste "hello\r"]
  check "a line pasted with its line break is one line, without it"
    (d.ui.pastedLines.isNone && d.ui.input.text.text == "hello")
  let d ← drive u [paste "hello\r\n"]
  check "and with CRLF" (d.ui.pastedLines.isNone && d.ui.input.text.text == "hello")
  let d ← drive u [paste "\r  def f():\r    return 1\r"]
  check "a paste keeps its first line's indent" (d.ui.pastedLines == some "  def f():\n    return 1")
  let d ← drive u [paste "one\ntwo", key .esc]
  check "Esc drops a paste of several lines, and does not quit" (d.ui.pastedLines.isNone && !d.quit)

def logs : TestM Unit := do
  let buf ← IO.mkRef ({} : IO.FS.Stream.Buffer)
  let lines ← IO.mkRef (#[] : Array String)
  let s := LogPane.stream Display.logLine (IO.FS.Stream.ofBuffer buf) lines fun _ => pure ()
  s.putStr "12:00:00.000 INFO jam: name \x1b]0;owned\x07 \u009b2J\n"
  let written := String.fromUTF8! (← buf.get).data
  check "the log file holds no control character but newlines"
    (clean (written.replace "\n" "") && (← lines.get).all clean)

/-- The style of the first cell in the conversation pane holding `ch`, on row `y` of it. -/
def styleAt (b : Buffer CS 100 30) (y : Nat) (ch : Char) : Option Tessera.Style :=
  ((List.range 50).find? fun x => match b.get (23 + x) (y + 2) with
    | .glyph g _ => g.char == ch
    | _ => false).map fun x => (b.get (23 + x) (y + 2)).style

def colours : TestM Unit := do
  let mine := ((chatWith [] []).group.map fun (g : Group) => g.me).getD .empty
  let c := chatWith [{ id := 0, sender := bob, text := "hello" },
    { id := 1, text := "bob added carol" }, { id := 2, sender := mine, text := "mine" }] [(bob, "bob")]
  let b := frame c
  check "a member's name is drawn in their colour, which is not one of jam's"
    (styleAt b 0 '~' == some (Theme.member bob).toStyle && !(Theme.member bob).toStyle.reserved)
  check "a notice is drawn in jam's style" (styleAt b 1 '-' == some Theme.notice && Theme.notice.reserved)
  check "me is drawn in jam's style" (styleAt b 2 'm' == some Theme.me && Theme.me.reserved)
  check "a member's colour is the same for the same key" (Theme.member bob == Theme.member (bob.extract 0 3))
  check "members' colours differ" (Theme.member bob != Theme.member carol)
  let plain := b.mapStyle (Style.downgrade .none)
  check "without colour, a notice is still drawn in a style no message has"
    (styleAt plain 1 '-' |>.any (·.reserved))
  check "and a member's name still is not"
    (styleAt plain 0 '~' |>.any (!·.reserved))
  check "without colour, nothing forbidden reaches a cell either" (cellsClean plain)

def tests : TestM Unit := do
  colours
  fuzz
  renderer
  spoofing
  names
  pastes
  logs

end Jam.Tests.Security
