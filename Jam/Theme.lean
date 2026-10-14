/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Tessera.Style

/-! # Colours

jam draws its own words, its notices, the frame and the bars in styles Tessera calls reserved
(`Style.reserved`): a bright or 24-bit colour, a background, dim or reverse video. A member's
name is drawn in a colour jam picks from their key, a `RemoteStyle`, which is never reserved
(`RemoteStyle.not_reserved`). So nothing a member sends or is called can be drawn the way jam
draws its own words, whatever colours the terminal shows: Tessera keeps each style as reserved
as it was when it draws in fewer colours (`Style.reserved_downgrade`). -/

namespace Jam.Theme

open Tessera

/-- jam's notices: `-- ~sam added ~kim`. -/
def notice : Style := { fg := some .brightYellow, bold := true }

/-- Our own name, `me`. -/
def me : Style := { fg := some (.rgb 255 121 198), bold := true }

/-- The frame of the pane being used, and the accent of the bars. -/
def accent : Style := { fg := some (.rgb 189 147 249) }

/-- The frame of the other panes. -/
def frame : Style := { fg := some (.rgb 98 114 164) }

/-- A pane's label. -/
def label : Style := { fg := some (.rgb 139 233 253), bold := true }

/-- The header bar, in segments of a gradient. -/
def header (i : Nat) : Style :=
  let shades : Array (UInt8 × UInt8 × UInt8) :=
    #[(255, 121, 198), (189, 147, 249), (98, 114, 164), (68, 71, 90), (40, 42, 54)]
  let (r, g, b) := shades[min i (shades.size - 1)]!
  { bg := some (.rgb r g b), fg := some (if i < 2 then .black else .brightWhite), bold := i < 2 }

/-- The status bar, and its keys. -/
def status : Style := { bg := some (.rgb 40 42 54), fg := some .brightWhite }
def statusKey : Style := { bg := some (.rgb 80 250 123), fg := some .black, bold := true }

/-- A note jam shows in the status bar. -/
def toast : Style := { bg := some (.rgb 255 184 108), fg := some .black, bold := true }

/-- How many lines of a conversation have not been seen. -/
def unread : Style := { bg := some (.rgb 255 85 85), fg := some .brightWhite, bold := true }

/-- A group still being joined or growing, or a hint: quieter than the rest. -/
def quiet : Style := { fg := some .brightBlack, italic := true }

/-- A name that could be taken for another's. -/
def warning : Style := { fg := some .brightRed, bold := true }

/-- The start of a member's key. -/
def key : Style := { fg := some .brightBlack }

/-- Our message, not written yet; written; read by a member. -/
def pending : Style := { fg := some .brightBlack }
def sent : Style := { fg := some (.rgb 80 250 123) }
def acknowledged : Style := { fg := some (.rgb 80 250 123), bold := true }

/-- The banner shown before there is a group, a colour a row. -/
def banner (i : Nat) : Style :=
  let shades : Array (UInt8 × UInt8 × UInt8) :=
    #[(255, 121, 198), (219, 134, 224), (189, 147, 249), (139, 233, 253)]
  let (r, g, b) := shades[i % shades.size]!
  { fg := some (.rgb r g b), bold := true }

/-- A log line's colour, by its level's tag. -/
def logLevel (tag : String) : Style :=
  match tag with
  | "CRIT" | "ERRO" => { fg := some .brightRed, bold := true }
  | "WARN" => { fg := some .brightYellow }
  | "NOTI" => { fg := some (.rgb 139 233 253) }
  | "DEBU" => { fg := some .brightBlack }
  | _ => { fg := some (.rgb 248 248 242) }

theorem notice_reserved : notice.reserved = true := by decide
theorem me_reserved : me.reserved = true := by decide
theorem header_reserved (i : Nat) : (header i).reserved = true := by
  simp [header, Style.reserved]
theorem logLevel_reserved (tag : String) : (logLevel tag).reserved = true := by
  unfold logLevel; split <;> decide

/-- The colours jam gives members: five of the eight basic ones, leaving out black and white,
which a terminal's background may hide, and yellow, which jam's notices are drawn in. -/
def memberColours : Array (Fin 8) := #[1, 2, 4, 5, 6]

/-- A member's colour, from their key: the same on every screen and every run. -/
def member (key : ByteArray) : RemoteStyle :=
  let h := key.data.foldl (fun h b => (h * 31 + b.toNat) % 1000003) 7
  { fg := memberColours[h % memberColours.size]?, bold := true }

/-- A member's colour is never one of jam's. -/
theorem member_not_reserved (key : ByteArray) : (member key).toStyle.reserved = false :=
  RemoteStyle.not_reserved _

end Jam.Theme
