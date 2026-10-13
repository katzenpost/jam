/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Posse.Tests.Live

/-! # posse against a real mixnet

Two members, each with its own connection to a client daemon: Alice founds a group, Bob joins it
with a voucher Alice inducts, and each reads the other's message; then Bob's next message
acknowledges Alice's. Each member runs as the app does, through a `Shell`, logging to standard
error.

Usage: `posse-integration [@katzenpost | PATH | HOST:PORT] [minutes]`. -/

open Posse Posse.Tests.Live Logger

def main (args : List String) : IO UInt32 := do
  let daemon := args.headD "@katzenpost"
  let minutes := (args[1]?.bind String.toNat?).getD 30
  let deadline := (← IO.monoMsNow) + minutes * 60000
  let dir : System.FilePath := ".lake/posse-integration"
  IO.FS.createDirAll dir
  let log ← Logger.new .stderr (← Level.fromEnv "POSSE_LOG" .info)
  let stop ← IO.mkRef false
  let alice ← member daemon "alice" dir log stop
  let bob ← member daemon "bob" dir log stop
  let ok ← (do
    alice.shell.post (.create "g")
    bob.shell.post (.join "g")
    unless ← waitFor alice "alice founds a group" deadline fun s => (s.chat? "g").any (·.group.isSome) do
      return false
    unless ← waitFor bob "bob mints a voucher" deadline (code? · |>.isSome) do return false
    let some code := code? (← bob.latest.get) | return false
    alice.shell.post (.induct "g" code)
    unless ← waitFor bob "bob joins" deadline fun s => (s.chat? "g").any (·.group.isSome) do
      return false
    unless ← waitFor alice "alice adds bob" deadline (heard · "added bob") do return false
    bob.shell.post (.send "g" "hello from bob")
    alice.shell.post (.send "g" "hello from alice")
    unless ← waitFor alice "alice reads bob" deadline (heard · "hello from bob") do return false
    unless ← waitFor bob "bob reads alice" deadline (heard · "hello from alice") do return false
    bob.shell.post (.send "g" "bob read you")
    waitFor alice "bob acknowledges alice's message" deadline fun s =>
      (s.chat? "g").any fun c => c.log.any fun l => l.text == "hello from alice" && acknowledged c l
    : IO Bool)
  stop.set true
  return if ok then 0 else 1
