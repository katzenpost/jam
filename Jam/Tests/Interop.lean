/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Tests.Live

/-! # jam with katzenqt

One jam member in group `g` with a katzenqt member, driven from a script beside
`katzenqt-headless`. As `host`, jam founds the group, reads a voucher code from standard input
and inducts its owner. As `guest`, jam mints a voucher, prints `VOUCHER=<code>` for katzenqt's
`voucher-induct`, and waits to be let in. Either way it then sends `from jam` and waits to read
`from katzenqt`, and for katzenqt to acknowledge its message.

Usage: `jam-interop host|guest [@katzenpost | PATH | HOST:PORT] [minutes]`. -/

open Jam Jam.Tests.Live Logger

def main (args : List String) : IO UInt32 := do
  let some role := args.head? | IO.eprintln "jam-interop host|guest [daemon] [minutes]"; return 2
  let daemon := args[1]?.getD "@katzenpost"
  let minutes := (args[2]?.bind String.toNat?).getD 30
  let deadline := (← IO.monoMsNow) + minutes * 60000
  let dir : System.FilePath := ".lake/jam-interop"
  IO.FS.createDirAll dir
  let log ← Logger.new .stderr (← Level.fromEnv "JAM_LOG" .info)
  let stop ← IO.mkRef false
  let me ← member daemon "jam" dir log stop
  let stdout ← IO.getStdout
  let ok ← (do
    if role == "host" then
      me.shell.post (.create "g")
      unless ← waitFor me "jam founds g" deadline fun s => (s.chat? "g").any (·.group.isSome) do
        return false
      stdout.putStrLn "READY"; stdout.flush
      let code := (← (← IO.getStdin).getLine).trimAscii.toString
      me.shell.post (.induct "g" code)
      unless ← waitFor me "jam adds the katzenqt member" deadline fun s =>
          (s.chat? "g").any fun c => c.log.any (·.text.startsWith "added ") do
        return false
    else
      me.shell.post (.join "g")
      unless ← waitFor me "jam mints a voucher" deadline (code? · |>.isSome) do return false
      let some code := code? (← me.latest.get) | return false
      stdout.putStrLn s!"VOUCHER={code}"; stdout.flush
      unless ← waitFor me "jam joins katzenqt's group" deadline fun s =>
          (s.chat? "g").any (·.group.isSome) do
        return false
    me.shell.post (.send "g" "from jam")
    unless ← waitFor me "jam reads katzenqt" deadline (heard · "from katzenqt") do return false
    waitFor me "katzenqt acknowledges jam's message" deadline fun s =>
      (s.chat? "g").any fun c => c.log.any fun l => l.text == "from jam" && acknowledged c l
    : IO Bool)
  stop.set true
  stdout.putStrLn (if ok then "OK" else "FAIL"); stdout.flush
  -- Tasks still blocked in daemon calls would keep the process alive.
  IO.Process.exit (if ok then 0 else 1)
