/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import Cryptlib.Protocols.GroupComm.GroupChatKatzenqt1.Member.Gcm

/-! # jam's command line -/

open Cryptlib.Protocols.GroupComm.GroupChatKatzenqt1.Member

structure Config where
  /-- The daemon's socket: a path, `@name` for an abstract one, or `HOST:PORT` over TCP. -/
  daemon : String := "@katzenpost"
  stateDir : Option System.FilePath := none
  logFile : Option System.FilePath := none
  name : Option String := none
  /-- What we write and mint: 3, the map forms, or 4, the arrays. Both are read. -/
  wireVersion : Nat := Gcm.currentVersion

def usage : String :=
  "usage: jam [--daemon @katzenpost | PATH | HOST:PORT] [--state DIR] [--name NAME] [--log FILE] [--wire-version 3|4]
The wire version, 4 by default, is what jam writes and mints; it reads both.
The log level is JAM_LOG: critical, error, warning, notice, info (the default) or debug."

def parseArgs : Config → List String → Except String Config
  | c, [] => pure c
  | c, "--daemon" :: d :: rest => parseArgs { c with daemon := d } rest
  | c, "--state" :: d :: rest => parseArgs { c with stateDir := some d } rest
  | c, "--log" :: f :: rest => parseArgs { c with logFile := some f } rest
  | c, "--name" :: n :: rest => parseArgs { c with name := some n } rest
  | c, "--wire-version" :: v :: rest =>
    if v == "3" || v == "4" then parseArgs { c with wireVersion := v.toNat! } rest
    else throw s!"the wire version is 3 or 4, not {v}"
  | _, a :: _ => throw s!"unknown argument: {a}"
