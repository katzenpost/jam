/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Tessera.Untrusted

/-! # What may reach the screen

Everything shown is `Shown`, Tessera's `Untrusted.Safe`: text from the network filtered by
`Tessera.Untrusted`, which keeps characters by an allowlist of those whose width the terminal and
Tessera agree on and shows anything else as a visible stand-in (`␛` for ESC, `␦` for the rest), so
an attempt to steer the terminal shows rather than vanishes. This module adds jam's own rules:
what a member's name may hold, and how long it may be. -/

namespace Jam.Display

open Tessera.Untrusted

abbrev Shown := Safe

/-- Text jam writes itself. -/
def ofApp (s : String) : Shown := Safe.trusted s

/-- Characters of a name shown. -/
def maxName : Nat := 30

/-- Characters a name may not hold, even where a message may: ones that look like jam's marks of
a message's state or of a verified member, or like the stand-ins for characters refused. -/
def badge (n : Nat) : Bool :=
  inRanges n [(0x2713, 0x2718), (0x2026, 0x2026), (0x1F512, 0x1F513), (0x1F6E1, 0x1F6E1),
    (0x2400, 0x2426)]

/-- One line of text from the network. -/
def text (s : String) : Shown := line s

/-- A message's text as lines, at most `Policy.maxLines` of them. -/
def body (s : String) : List Shown := lines s

/-- A member's name: one line, no character that could pass for one of jam's marks, and no
longer than `maxName` characters. -/
def name (s : String) : Shown :=
  let kept := String.ofList ((line s).text.toList.map fun c => if badge c.toNat then substitute else c)
  let kept := if kept.isEmpty then "?" else kept
  -- Every character left is one the filter keeps, so filtering again changes nothing.
  line (if kept.length > maxName then (kept.take (maxName - 1)).toString ++ "…" else kept)

/-- Text the user typed or pasted, as it is sent: without control characters other than newlines
and tabs, and without bidi controls, which another client might obey. -/
def outgoing (s : String) : String := withoutControls s

/-- Text written to the log: one line, filtered, so that reading the log in a terminal is safe. -/
def logLine (s : String) : String := (line s).text

end Jam.Display
