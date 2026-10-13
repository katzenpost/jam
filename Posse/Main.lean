/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Posse.Daemon
import Posse.LogPane
import Posse.Shell
import Posse.Sim
import Posse.Ui

/-! # posse

A terminal group chat over the Katzenpost mixnet that speaks katzenqt's group chat. -/

open Posse Logger
open CryptWalker.GroupChat.Member.Persist

structure Config where
  /-- The daemon's socket: a path, `@name` for an abstract one, or `HOST:PORT` over TCP. -/
  daemon : String := "@katzenpost"
  stateDir : Option System.FilePath := none
  logFile : Option System.FilePath := none
  name : Option String := none
  /-- An in-memory network instead of the daemon, to try posse alone. -/
  sim : Bool := false

def usage : String :=
  "usage: posse [--daemon @katzenpost | PATH | HOST:PORT] [--state DIR] [--name NAME] [--log FILE] [--sim]
The log level is POSSE_LOG: critical, error, warning, notice, info (the default) or debug."

def parseArgs : Config → List String → Except String Config
  | c, [] => pure c
  | c, "--daemon" :: d :: rest => parseArgs { c with daemon := d } rest
  | c, "--state" :: d :: rest => parseArgs { c with stateDir := some d } rest
  | c, "--log" :: f :: rest => parseArgs { c with logFile := some f } rest
  | c, "--name" :: n :: rest => parseArgs { c with name := some n } rest
  | c, "--sim" :: rest => parseArgs { c with sim := true } rest
  | _, a :: _ => throw s!"unknown argument: {a}"

def defaultStateDir : IO System.FilePath := do
  let base ← match ← IO.getEnv "XDG_DATA_HOME" with
    | some d => pure (d : System.FilePath)
    | none => pure ((← IO.getEnv "HOME").getD "." / ".local" / "share")
  pure (base / "posse" / ((← IO.getEnv "POSSE_STATE").getD "default"))

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
  | .error e => throw (IO.userError s!"connecting to the daemon at {daemon}: {e}")

def main (args : List String) : IO UInt32 := do
  let cfg ← match parseArgs {} args with
    | .ok c => pure c
    | .error e => IO.eprintln s!"{e}\n{usage}"; return 2
  let dir ← match cfg.stateDir with
    | some d => pure d
    | none => defaultStateDir
  IO.FS.createDirAll dir
  let logFile ← Logger.Output.open (.file (cfg.logFile.getD (dir / "posse.log")))
  let logLines ← IO.mkRef (#[] : Array String)
  -- The pane shows the log once the UI is up; until then lines only go to the file.
  let showLogs ← IO.mkRef (fun (_ : Array String) => (pure () : IO Unit))
  let log ← Logger.new (.stream (LogPane.stream logFile logLines fun ls => do (← showLogs.get) ls))
    (← Level.fromEnv "POSSE_LOG" .info) "posse"
  let statePath := dir / "state.cbor"
  let saved : Option State ← if ← statePath.pathExists then
      pure (load (← IO.FS.readBinFile statePath))
    else pure none
  if (← statePath.pathExists) && saved.isNone then
    IO.eprintln s!"{statePath} cannot be read"; return 1
  let me := cfg.name.getD ((saved.map (·.me)).getD ((← IO.getEnv "USER").getD "me"))
  let state := { (saved.getD { me }) with me }
  let (backend, client) ← if cfg.sim then
      pure (Sim.backend (← IO.mkRef {}), none)
    else
      IO.println s!"connecting to the client daemon at {cfg.daemon}"
      let c ← connect cfg.daemon
      pure (Daemon.backend c, some c)
  log.notice s!"started as {me}, state in {dir}{if cfg.sim then ", simulated network" else ""}"
  let (core, resumed) := resume state (← backend.maxPlaintext)
  let stop ← IO.mkRef false
  let inbox ← Std.CloseableChannel.new (α := Msg)
  try
    let network := if cfg.sim then "simulated network" else s!"daemon {cfg.daemon}"
    discard <| Tessera.App.run { draw := Ui.draw, update := Ui.update fun m => discard (inbox.send m) }
      (Ui.markSeen { state := core.state, network, logs := ← logLines.get }) fun post => do
        showLogs.set (post ∘ .logs)
        let sh : Shell := { backend, core := ← IO.mkRef core, inbox, log, statePath,
                            display := post ∘ .state, stop }
        sh.start resumed
  finally
    showLogs.set fun _ => pure ()
    stop.set true
    discard <| inbox.close
    if let some c := client then
      discard <| (c.close false).block
  log.notice "stopped"
  return 0
