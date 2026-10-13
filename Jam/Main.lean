/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Jam.Daemon
import Jam.LogPane
import Jam.Shell
import Jam.Ui
import Jam.Display

/-! # jam

A terminal group chat over the Katzenpost mixnet that speaks katzenqt's group chat. -/

open Jam Logger
open CryptWalker.GroupChat.Member.Persist

structure Config where
  /-- The daemon's socket: a path, `@name` for an abstract one, or `HOST:PORT` over TCP. -/
  daemon : String := "@katzenpost"
  stateDir : Option System.FilePath := none
  logFile : Option System.FilePath := none
  name : Option String := none

def usage : String :=
  "usage: jam [--daemon @katzenpost | PATH | HOST:PORT] [--state DIR] [--name NAME] [--log FILE]
The log level is JAM_LOG: critical, error, warning, notice, info (the default) or debug."

def parseArgs : Config → List String → Except String Config
  | c, [] => pure c
  | c, "--daemon" :: d :: rest => parseArgs { c with daemon := d } rest
  | c, "--state" :: d :: rest => parseArgs { c with stateDir := some d } rest
  | c, "--log" :: f :: rest => parseArgs { c with logFile := some f } rest
  | c, "--name" :: n :: rest => parseArgs { c with name := some n } rest
  | _, a :: _ => throw s!"unknown argument: {a}"

def defaultStateDir : IO System.FilePath := do
  let base ← match ← IO.getEnv "XDG_DATA_HOME" with
    | some d => pure (d : System.FilePath)
    | none => pure ((← IO.getEnv "HOME").getD "." / ".local" / "share")
  pure (base / "jam" / ((← IO.getEnv "JAM_STATE").getD "default"))

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

/-- Put the terminal back as it was: for a signal, which ends jam without unwinding. -/
def restoreTerminal : IO Unit := do
  try CrosstermFfi.disableBracketedPaste catch _ => pure ()
  try CrosstermFfi.showCursor catch _ => pure ()
  try CrosstermFfi.leaveAlternateScreen catch _ => pure ()
  try CrosstermFfi.disableRawMode catch _ => pure ()

/-- On SIGTERM, SIGHUP or SIGQUIT, restore the terminal before exiting, so that it is not left in
raw mode with the conversation on it. -/
def onSignals (log : Logger) : IO Unit := do
  for (sig, n) in [(Std.Async.Signal.sigterm, 15), (.sighup, 1), (.sigquit, 3)] do
    let w ← Std.Async.Signal.Waiter.mk sig false
    let t ← w.wait
    discard <| IO.asTask (prio := .dedicated) do
      discard <| IO.wait t
      restoreTerminal
      log.notice s!"stopped by signal {n}"
      (IO.Process.exit (128 + n).toUInt8 : IO Unit)

/-- Hand the UI the latest state at most every `ms` milliseconds, however often it changes. -/
def coalesce (post : State → IO Unit) (stop : IO.Ref Bool) (ms : UInt32 := 33) :
    IO (State → IO Unit) := do
  let latest ← IO.mkRef (none : Option State)
  discard <| IO.asTask (prio := .dedicated) do
    while !(← stop.get) do
      IO.sleep ms
      if let some s ← latest.modifyGet (·, none) then post s
  return fun s => latest.set (some s)

def main (args : List String) : IO UInt32 := do
  try run args
  catch e =>
    restoreTerminal
    IO.eprintln (Display.text (toString e)).text
    return 1
where
  run (args : List String) : IO UInt32 := do
  let cfg ← match parseArgs {} args with
    | .ok c => pure c
    | .error e => IO.eprintln s!"{e}\n{usage}"; return 2
  let dir ← match cfg.stateDir with
    | some d => pure d
    | none => defaultStateDir
  IO.FS.createDirAll dir
  IO.setAccessRights dir { user := { read := true, write := true, execution := true } }
  let logPath := cfg.logFile.getD (dir / "jam.log")
  let logFile ← Logger.Output.open (.file logPath)
  IO.setAccessRights logPath Shell.private_
  let logLines ← IO.mkRef (#[] : Array String)
  -- The pane shows the log once the UI is up; until then lines only go to the file.
  let showLogs ← IO.mkRef (fun (_ : Array String) => (pure () : IO Unit))
  let log ← Logger.new (.stream (LogPane.stream logFile logLines fun ls => do (← showLogs.get) ls))
    (← Level.fromEnv "JAM_LOG" .info) "jam"
  let statePath := dir / "state.cbor"
  let saved : Option State ← if ← statePath.pathExists then
      pure (load (← IO.FS.readBinFile statePath))
    else pure none
  if (← statePath.pathExists) && saved.isNone then
    IO.eprintln s!"{statePath} cannot be read"; return 1
  let me := cfg.name.getD ((saved.map (·.me)).getD ((← IO.getEnv "USER").getD "me"))
  let state := { (saved.getD { me }) with me }
  IO.println s!"connecting to the client daemon at {cfg.daemon}"
  let client ← connect cfg.daemon
  let backend := Daemon.backend client
  log.notice s!"started as {me}, state in {dir}"
  let (core, resumed) := resume state (← backend.maxPlaintext)
  let stop ← IO.mkRef false
  let inbox ← Std.CloseableChannel.new (α := Msg)
  onSignals log
  try
    let network := s!"daemon {cfg.daemon}"
    discard <| Tessera.App.run { draw := Ui.draw, update := Ui.update fun m => discard (inbox.send m) }
      (Ui.markSeen { state := core.state, network, logs := ← logLines.get }) fun post => do
        showLogs.set (post ∘ .logs)
        let display ← coalesce (post ∘ .state) stop
        let sh : Shell := { backend, core := ← IO.mkRef core, inbox, log, statePath, display, stop }
        sh.start resumed
  finally
    showLogs.set fun _ => pure ()
    stop.set true
    discard <| inbox.close
    discard <| (client.close false).block
  log.notice "stopped"
  -- Tasks still blocked in daemon calls would keep the process alive.
  IO.Process.exit 0
