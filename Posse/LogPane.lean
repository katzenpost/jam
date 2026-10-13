/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Posse.Display

/-! # Log lines on screen

A stream for the logger that writes each line to the log file and also keeps the last ones, to be
shown in a pane. Each line is filtered first, as text from the network is for the screen: a log
quotes names and errors that came from elsewhere, and someone will read it in a terminal. -/

namespace Posse.LogPane

/-- How many lines the pane keeps. -/
def keep : Nat := 200

/-- Write through to `file`, keeping the last `keep` whole lines in `lines` and calling `shown`
with them after each. -/
def stream (file : IO.FS.Stream) (lines : IO.Ref (Array String))
    (shown : Array String → IO Unit) : IO.FS.Stream :=
  { file with
    putStr := fun s => do
      let new := ((s.splitOn "\n").filter (!·.isEmpty)).map Display.logLine
      file.putStr (String.join (new.map (· ++ "\n")))
      let all ← lines.modifyGet fun ls =>
        let ls := ls ++ new.toArray
        let ls := ls.extract (ls.size - min ls.size keep) ls.size
        (ls, ls)
      shown all }

end Posse.LogPane
