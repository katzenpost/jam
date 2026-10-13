/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Posse.Daemon
import Posse.Shell

/-! # Members on a real mixnet

posse members run as the app runs them, through a `Shell`, each with its own connection to a
client daemon, for the tests that need a mixnet. -/

namespace Posse.Tests.Live

open Posse Logger

def connect (daemon : String) : IO ThinClient.Client := do
  let dial ← if daemon.startsWith "@" || daemon.startsWith "/" then
      pure (ThinClient.Client.connectUnix daemon)
    else
      match daemon.splitOn ":" with
      | [host, port] =>
        let some addr := Std.Net.IPv4Addr.ofString host
          | throw (IO.userError s!"not an IPv4 address: {host}")
        pure (ThinClient.Client.connect (.v4 addr) port.toNat!.toUInt16)
      | _ => throw (IO.userError s!"not a socket or HOST:PORT: {daemon}")
  match ← dial.run.block with
  | .ok c => pure c
  | .error e => throw (IO.userError s!"connecting to {daemon}: {e}")

structure Member where
  shell : Shell
  latest : IO.Ref State

def member (daemon : String) (me : String) (dir : System.FilePath) (log : Logger)
    (stop : IO.Ref Bool) : IO Member := do
  let client ← connect daemon
  let backend := Daemon.backend client
  let latest ← IO.mkRef ({ me } : State)
  let (core, resumed) := resume { me } (← backend.maxPlaintext)
  let shell : Shell :=
    { backend, core := ← IO.mkRef core, inbox := ← Std.CloseableChannel.new,
      log := log.withModule s!"posse/{me}", statePath := dir / s!"{me}.cbor",
      display := latest.set, stop }
  shell.start resumed
  pure { shell, latest }

def heard (s : State) (text : String) : Bool :=
  (s.chat? "g").any fun c => c.log.any (·.text == text)

/-- Wait until `p` holds of a member's state, up to `deadline` (monotonic ms). -/
partial def waitFor (m : Member) (what : String) (deadline : Nat) (p : State → Bool) : IO Bool := do
  if p (← m.latest.get) then
    IO.eprintln s!"ok   {what}"
    return true
  if (← IO.monoMsNow) > deadline then
    IO.eprintln s!"FAIL {what}: timed out"
    return false
  IO.sleep 1000
  waitFor m what deadline p

def code? (s : State) : Option String := do
  match (← s.chat? "g").joining with
  | some (.awaiting code ..) => some code
  | _ => none

end Posse.Tests.Live
