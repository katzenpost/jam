/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

/-! # What may reach the screen

Everything shown passes through here and comes out as `Shown`, whose constructor is private: the
UI draws `Shown` and nothing else, so text from the network cannot reach the terminal unfiltered.

Filtering keeps characters by an allowlist, not a blocklist. A character is kept only when it is
printable and the terminal and posse agree on its width; anything else becomes a visible stand-in,
never silently dropped, so an attempt shows. Control characters show as their Control Pictures
(`␛` for ESC, `␤` for a newline in a name), DEL as `␡`, and every other character refused as `␦`.

Agreeing on width matters: posse lays the screen out by its own idea of each character's width,
and a character the terminal draws wider or narrower moves everything after it on the row, into
the next pane. So the allowlist holds the scripts and symbols terminals draw one cell wide, the CJK
and emoji ranges posse draws two cells wide, and combining accents, which take none, at most
`maxMarks` to a letter. East Asian ambiguous-width characters are taken as one cell, as terminals
outside CJK locales draw them. -/

namespace Posse.Display

/-- Text that may be drawn. -/
structure Shown where
  private mk ::
  text : String
  deriving Inhabited, BEq

/-- Text posse writes itself. -/
def ofApp (s : String) : Shown := ⟨s⟩

instance : Append Shown := ⟨fun a b => ⟨a.text ++ b.text⟩⟩

/-- The stand-in for a character refused. -/
def substitute : Char := '␦'

/-- Combining marks kept on one letter. -/
def maxMarks : Nat := 4

/-- Lines of one message shown. -/
def maxLines : Nat := 20

/-- Characters of a name shown. -/
def maxName : Nat := 30

def inRanges (n : Nat) (rs : List (Nat × Nat)) : Bool := rs.any fun (lo, hi) => lo ≤ n && n ≤ hi

/-- Accents drawn on the letter before them, which posse and terminals give no width. -/
def combining (n : Nat) : Bool := 0x300 ≤ n && n ≤ 0x36F

/-- One cell wide, to posse and to terminals. -/
def narrow (n : Nat) : Bool :=
  inRanges n [
    (0x20, 0x7E), (0xA0, 0xAC), (0xAE, 0x2FF),        -- Latin; not the soft hyphen
    (0x370, 0x377), (0x37A, 0x37F), (0x384, 0x3FF),   -- Greek
    (0x400, 0x482), (0x48A, 0x52F),                   -- Cyrillic, not its combining marks
    (0x531, 0x556), (0x561, 0x587),                   -- Armenian
    (0x5D0, 0x5EA),                                   -- Hebrew letters
    (0x621, 0x64A),                                   -- Arabic letters
    (0x10A0, 0x10FF),                                 -- Georgian
    (0x1E00, 0x1FFE),                                 -- Latin and Greek extended
    (0x2010, 0x2027), (0x2030, 0x205E),               -- punctuation, not the invisibles
    (0x2070, 0x209C), (0x20A0, 0x20C0),               -- super- and subscripts, currency
    (0x2100, 0x214F), (0x2150, 0x218B),               -- letterlike, number forms
    (0x2190, 0x21FF), (0x2200, 0x22FF),               -- arrows, mathematics
    (0x2400, 0x2426),                                 -- control pictures
    (0x2500, 0x257F)]                                 -- box drawing

/-- Two cells wide, to posse and to terminals: CJK, Hangul and the emoji posse draws wide. -/
def wide (n : Nat) : Bool :=
  inRanges n [(0x1100, 0x115F), (0x2E80, 0x303E), (0x3041, 0x33FF), (0x3400, 0x4DBF),
    (0x4E00, 0x9FFF), (0xA000, 0xA4CF), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFF01, 0xFF60),
    (0xFFE0, 0xFFE6), (0x1F300, 0x1F64F), (0x1F900, 0x1F9FF), (0x20000, 0x2FFFD),
    (0x30000, 0x3FFFD)]

/-- Characters a name may not hold, even where text may: ones that look like posse's own marks
of a message's state or of a verified member. -/
def badge (n : Nat) : Bool :=
  inRanges n [(0x2713, 0x2718), (0x2026, 0x2026), (0x1F512, 0x1F513), (0x1F6E1, 0x1F6E1),
    (0x2400, 0x2426)]

/-- What a character refused shows as. -/
def standIn (n : Nat) : Char :=
  if n < 0x20 then Char.ofNat (0x2400 + n)
  else if n == 0x7F then '␡'
  else substitute

/-- One line of text, filtered: marks capped on each letter. -/
def line (s : String) : String := Id.run do
  let mut out := ""
  let mut marks := 0
  let mut letter := false
  for c in s.toList do
    let n := c.toNat
    if combining n then
      if letter && marks < maxMarks then
        out := out.push c
        marks := marks + 1
      else if letter && marks == maxMarks then
        out := out.push substitute
        marks := marks + 1
      else if !letter then
        out := out.push substitute
    else if narrow n || wide n then
      out := out.push c
      marks := 0
      letter := true
    else
      out := out.push (standIn n)
      marks := 0
      letter := false
  return out

/-- A message's text as lines: the newlines its sender wrote, never more than `maxLines` of them,
the last saying how many more there were. Tabs become spaces, and a carriage return shows. -/
def body (s : String) : List Shown :=
  let ls := ((s.replace "\r\n" "\n").splitOn "\n").map fun l => line (l.replace "\t" "    ")
  if ls.length ≤ maxLines then ls.map (⟨·⟩)
  else (ls.take (maxLines - 1)).map (⟨·⟩) ++
    [⟨s!"[{ls.length - (maxLines - 1)} more lines not shown]"⟩]

/-- One line of text: a newline shows, as everything else refused does. -/
def text (s : String) : Shown := ⟨line s⟩

/-- A name: one line, no character that could pass for one of posse's marks, and no longer than
`maxName` characters. -/
def name (s : String) : Shown :=
  let kept := String.ofList ((line s).toList.map fun c => if badge c.toNat then substitute else c)
  let kept := if kept.isEmpty then "?" else kept
  ⟨if kept.length > maxName then (kept.take (maxName - 1)).toString ++ "…" else kept⟩

/-! ## Names that look alike -/

/-- Letters of other scripts drawn like Latin ones, and digits like letters, as the Latin letter
they pass for. A small part of UTS #39's confusables, for the scripts posse shows. -/
def confusables : List (Char × Char) :=
  [('а', 'a'), ('е', 'e'), ('о', 'o'), ('р', 'p'), ('с', 'c'), ('у', 'y'), ('х', 'x'),
   ('і', 'i'), ('ј', 'j'), ('ѕ', 's'), ('һ', 'h'), ('ԁ', 'd'), ('ɡ', 'g'), ('ӏ', 'l'),
   ('α', 'a'), ('ο', 'o'), ('ν', 'v'), ('ρ', 'p'), ('τ', 't'), ('ι', 'i'), ('κ', 'k'),
   ('А', 'a'), ('В', 'b'), ('Е', 'e'), ('К', 'k'), ('М', 'm'), ('Н', 'h'), ('О', 'o'),
   ('Р', 'p'), ('С', 'c'), ('Т', 't'), ('Х', 'x'), ('Α', 'a'), ('Β', 'b'), ('Ε', 'e'),
   ('Ζ', 'z'), ('Η', 'h'), ('Ι', 'i'), ('Κ', 'k'), ('Μ', 'm'), ('Ν', 'n'), ('Ο', 'o'),
   ('Ρ', 'p'), ('Τ', 't'), ('Χ', 'x'), ('Υ', 'y'),
   ('0', 'o'), ('1', 'l'), ('I', 'l'), ('|', 'l'), ('5', 's'), ('$', 's')]

/-- What a name looks like, ignoring case, look-alike letters, accents and spaces: two names with
one skeleton are easily mistaken for each other. -/
def skeleton (s : String) : String :=
  String.ofList <| (line s).toList.filterMap fun c =>
    if combining c.toNat || c == ' ' || c == '_' || c == '-' || c == '.' then none
    else some ((confusables.lookup c).getD c.toLower)

/-- Whether a name mixes Latin letters with Greek or Cyrillic ones, as a forged name might. -/
def mixedScript (s : String) : Bool :=
  let latin := s.any fun c => c.isAlpha
  let other := s.any fun c => 0x370 ≤ c.toNat && c.toNat ≤ 0x52F
  latin && other

/-- Text the user typed or pasted, as it is sent: without control characters other than newlines
and tabs, and without bidi controls, which another client might obey. -/
def outgoing (s : String) : String :=
  String.ofList <| s.toList.filter fun c =>
    let n := c.toNat
    c == '\n' || c == '\t' ||
      !(n < 0x20 || (0x7F ≤ n && n < 0xA0) || inRanges n [(0x202A, 0x202E), (0x2066, 0x2069),
        (0x200E, 0x200F), (0x61C, 0x61C)])

/-- Text written to the log: one line, filtered, so that reading the log in a terminal is safe. -/
def logLine (s : String) : String := line s

end Posse.Display
