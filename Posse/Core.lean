/-
SPDX-FileCopyrightText: Copyright (C) 2026 David Stainton
SPDX-License-Identifier: AGPL-3.0-only
-/

import CryptWalker.GroupChat.Member.Gcm
import CryptWalker.GroupChat.Member.Membership
import CryptWalker.GroupChat.Member.ReplyWho
import Posse.Base64
import Posse.Display
import Posse.State

/-! # What posse does

`step` takes posse's state and one message, from the user or from the network, and returns the
new state and the network work it asks for. It does no IO, so it can be tested on its own; the
shell carries out each `Action` and sends back what came of it as another `Msg`.

The member state machine is driven as katzenqt's adapter (`acks.py`) drives it: `compose` for
each message sent, `written` once its box is written, `observe` for each box read in order,
`handle` for a new epoch and for a user's scan, and for a new member `beginInduction`, then once
everything owed is written `reply`, then `introduceNow`. -/

namespace Posse

open CryptWalker.GroupChat.Member

/-- Network work. Each comes back as the `Msg` named. -/
inductive Action
  /-- A new stream: `created`. -/
  | create (chat : String) (joining : Bool)
  /-- Write a box, retrying until it is written: `wrote`. -/
  | write (chat : String) (job : Nat) (writeCap : ByteArray) (index : Index) (box : ByteArray)
  /-- Read a box once: `read`. -/
  | read (chat : String) (stream : Key) (readCap : ByteArray) (index : Index)
  /-- Send `wake` after `ms` milliseconds. -/
  | wake (chat : String) (stream : Key) (ms : Nat)
  /-- Read a box once for a scan: `scanRead`. -/
  | scanRead (chat : String) (stream : Key) (readCap : ByteArray) (index : Index)
  /-- `walked`. -/
  | walk (chat : String) (stream : Key) (start : Index) (targets : List Nat) (keep : Nat)
  /-- `derived`. -/
  | derive (chat : String) (stream : Key) (start : Index) (count : Nat)
  /-- Mint a voucher and publish its box 0: `minted`. -/
  | mint (chat : String) (writeCap : ByteArray) (name : String)
  /-- Wait for the reply in box 1 and open it: `opened`. -/
  | awaitReply (chat : String) (secretKey voucherReadCap : ByteArray) (box1 : Index)
      (writeCap : ByteArray)
  /-- Read a voucher's box 0: `joinerPayload`. -/
  | readVoucher (chat : String) (voucher : ByteArray)
  /-- Seal the reply and publish it to box 1: `inducted`. -/
  | induct (chat : String) (voucher payload whoReply voucherWriteCap : ByteArray) (box1 : Index)

inductive Msg
  | create (chat : String)
  | join (chat : String)
  | induct (chat : String) (code : String)
  | send (chat : String) (text : String)
  | scan (chat : String)
  /-- Forget a group: stop reading and writing it, and delete it. -/
  | leave (chat : String)
  /-- Stop reading a member, named by display name or by the start of its key in hex. -/
  | remove (chat : String) (who : String)
  /-- Delete a conversation's lines here. -/
  | clear (chat : String)
  | created (chat : String) (joining : Bool) (kp : Keypair)
  | wrote (chat : String) (job : Nat) (index next : Index)
  | read (chat : String) (stream : Key) (index : Index) (outcome : ReadOutcome)
  | wake (chat : String) (stream : Key)
  | scanRead (chat : String) (stream : Key) (index : Index) (outcome : ReadOutcome)
  | walked (chat : String) (stream : Key) (target : Option Index) (skipped : List Index)
      (steps : Nat)
  | derived (chat : String) (stream : Key) (indexes : List Index)
  | minted (chat : String) (m : Minted) (box1 : Index)
  | opened (chat : String) (o : Opened)
  | joinerPayload (chat : String) (voucher voucherWriteCap payload : ByteArray) (box1 : Index)
  | inducted (chat : String) (i : Inducted)
  | epoch (n : Nat)
  | failed (chat : String) (what : String)

/-- What is under way on the network; not saved, since a restart begins it again. -/
structure Flight where
  writing : List String := []
  /-- Streams with a read out or a wake pending. -/
  reading : List (String × Key) := []
  /-- Reads of each stream that found nothing, in a row. -/
  misses : List ((String × Key) × Nat) := []
  deriving Inhabited

structure Core where
  state : State
  flight : Flight := {}
  maxPlaintext : Nat := 1530
  deriving Inhabited

abbrev CoreM := StateM (Core × Array Action)

namespace Core

def emit (a : Action) : CoreM Unit := modify fun (c, as) => (c, as.push a)

def getChat (name : String) : CoreM (Option Chat) := return (← get).1.state.chat? name

def setChat (c : Chat) : CoreM Unit :=
  modify fun (core, as) => ({ core with state := core.state.setChat c }, as)

def me : CoreM String := return (← get).1.state.me

def modifyFlight (f : Flight → Flight) : CoreM Unit :=
  modify fun (c, as) => ({ c with flight := f c.flight }, as)

def getFlight : CoreM Flight := return (← get).1.flight

/-- Run a member's step on `c`'s group. -/
def onGroup {α : Type} (c : Chat) (x : GM α) (default : α) : α × Chat :=
  match c.group with
  | none => (default, c)
  | some g => let (a, g) := x.run g; (a, { c with group := some g })

/-! ## Writing -/

/-- Every member's read cap, ourselves as one of them. -/
def memberCaps (g : Group) : List ByteArray := g.readCap :: g.readers.values.map (·.readCap)

/-- The box an outgoing message is written as. A message the member makes itself carries our
membership hash, an `Introduction` the hash before the member it introduces; content carries the
hash it was composed with. -/
def boxOf (g : Group) (o : Outgoing) : Option ByteArray := do
  let gcm ← Gcm.ofMessage o.message
  let gcm := if o.message.content.isSome then gcm else
    let caps := match o.message.introduction with
      | some i => (memberCaps g).filter fun c => keyOf c != keyOf i.readCap
      | none => memberCaps g
    { gcm with membershipHash := membershipHash caps }
  some (Gcm.frame (Gcm.encode gcm))

/-- Queue `outgoing`, each written after the one before; `line` shows the one carrying
`content`. A message too long for a box is abandoned. -/
def enqueue (c : Chat) (outgoing : List Outgoing) (content : Option ByteArray := none)
    (line : Option Nat := none) : CoreM Chat := do
  let max := (← get).1.maxPlaintext
  let mut c := c
  for o in outgoing do
    let some g := c.group | pure ()
    let mine := content.isSome && o.message.content.map (·.data) == content.map (·.data)
    match boxOf g o with
    | some box =>
      if box.size ≤ max then
        let (id, c') := c.fresh
        c := { c' with jobs := c'.jobs ++ [{ id, token := some o.token, box,
                                             line := if mine then line else none }] }
        continue
    | none => pure ()
    c := (onGroup c (Group.abandoned o.token) ()).2
    c := c.notice (if mine then "that message is too long to send" else "a message could not be written")
  return c

/-- A box the member asks to write again, or to tombstone. -/
def rewrite (c : Chat) (index : Index) (box : ByteArray) : Chat :=
  let (id, c) := c.fresh
  { c with jobs := c.jobs ++ [{ id, index := some index, box }] }

/-! ## Reading -/

def textOf (content : ByteArray) : String :=
  match Gcm.decode content with
  | some g =>
    if g.msgType = Gcm.MsgType.text then g.text.getD ""
    else if g.msgType = Gcm.MsgType.fileUpload then "[a file, which posse cannot show yet]"
    else "[a message posse cannot show]"
  | none => "[a message posse cannot read]"

/-- Do what the member asks. -/
def effects (c : Chat) (es : List Effect) : CoreM Chat := do
  let mut c := c
  for e in es do
    match e with
    | .writeBox index payload =>
      let box := match payload with
        | .bytes b => some b
        | .message m => Gcm.box m
      if let some box := box then c := rewrite c index box
    | .writeTombstone index => c := rewrite c index .empty
    | .readBox stream readCap index _ => emit (.scanRead c.name stream readCap index)
    | .deriveIndexes stream start count => emit (.derive c.name stream start count)
    | .walk stream start targets keep => emit (.walk c.name stream start targets keep)
    | .deliver sender index content =>
      c := (c.say fun id => { id, sender, index, text := textOf content }).2
    | .expire sender index =>
      c := { c with log := c.log.filter fun l => !(l.sender == sender && l.index == index) }
    | .sendJoinReply .. => pure ()
  return c

/-- What a box holds, as a member reads it. -/
def messageOf (plaintext : ByteArray) : Option Message :=
  match Gcm.unframe plaintext with
  | .final cbor => Gcm.toMessage cbor
  | _ => none

/-- A member as a notice names them: `me`, or the name they chose, filtered, after `~`. -/
def label (c : Chat) (key : Key) : String :=
  if c.group.any (·.me == key) then "me"
  else "~" ++ (Display.name ((c.names.get? key).getD "?")).text

/-- Notes for the conversation about a box: who an `Introduction` introduced, or a message posse
cannot show. -/
def remark (c : Chat) (stream : Key) (plaintext : ByteArray) : Chat :=
  match Gcm.unframe plaintext with
  | .final cbor =>
    match (Gcm.toMessage cbor).bind (·.introduction) with
    | some i =>
      let c := { c with names := c.names.setDefault (keyOf i.readCap) i.name }
      if c.group.any (·.me == keyOf i.readCap) then c
      else c.notice s!"{label c stream} added ~{(Display.name i.name).text}"
    | none => c
  | .indirection .. | .continued _ =>
    c.notice s!"{label c stream} sent a long message, which posse cannot show yet"
  | .unknown => c

/-! ## Under way -/

def readingNow (chat : String) (stream : Key) : CoreM Bool :=
  return (← getFlight).reading.any fun (c, k) => c == chat && k == stream

def startReads (c : Chat) : CoreM Chat := do
  let some g := c.group | return c
  let mut c := c
  for r in g.readers.values do
    if ← readingNow c.name r.stream then continue
    let at_ := c.cursors.getD r.stream r.next
    c := { c with cursors := c.cursors.set r.stream at_ }
    modifyFlight fun f => { f with reading := (c.name, r.stream) :: f.reading }
    emit (.read c.name r.stream r.readCap at_)
  return c

def startWrite (c : Chat) : CoreM Chat := do
  if (← getFlight).writing.contains c.name || c.writeCap.size = 0 then return c
  match c.jobs with
  | [] => return c
  | j :: rest =>
    let index := j.index.getD c.nextWrite
    modifyFlight fun f => { f with writing := c.name :: f.writing }
    emit (.write c.name j.id c.writeCap index j.box)
    return { c with jobs := { j with index := some index } :: rest }

/-- Hand the new member its reply, once everything owed is written. -/
def startInduction (c : Chat) : CoreM Chat := do
  let some i := c.inducting | return c
  let some g := c.group | return c
  if i.sealing || c.jobs.any (·.token.isSome) then return c
  let name ← me
  let who := ReplyWho.ofJoinReply (g.reply c.nextWrite) fun key =>
    if key == g.me then some name else c.names.get? key
  emit (.induct c.name i.voucher i.payload (ReplyWho.encode who) i.voucherWriteCap i.box1)
  return { c with inducting := some { i with sealing := true } }

/-- Start whatever can start. -/
def pump : CoreM Unit := do
  for c in (← get).1.state.chats do
    let c ← startWrite c
    let c ← startReads c
    let c ← startInduction c
    setChat c

def withChat (name : String) (f : Chat → CoreM Chat) : CoreM Unit := do
  if let some c ← getChat name then setChat (← f c)

def stopReading (chat : String) (stream : Key) : CoreM Unit :=
  modifyFlight fun f => { f with reading := f.reading.filter fun (c, k) => !(c == chat && k == stream) }

def missed (chat : String) (stream : Key) : CoreM Nat := do
  let n := ((← getFlight).misses.lookup (chat, stream)).getD 0
  modifyFlight fun f => { f with misses := ((chat, stream), n + 1) :: f.misses.filter (·.1 != (chat, stream)) }
  return n

def hit (chat : String) (stream : Key) : CoreM Unit :=
  modifyFlight fun f => { f with misses := f.misses.filter (·.1 != (chat, stream)) }

/-- How long to wait before reading a box that was not there, after `n` misses before. -/
def backoff (n : Nat) : Nat := min 60000 (2000 * 2 ^ (min n 5))

/-- Move a cursor that a scan has carried past it. -/
def followReader (c : Chat) (stream : Key) : Chat :=
  match c.group.bind (·.readers.get? stream), c.cursors.get? stream with
  | some r, some at_ => if counter at_ < counter r.next then { c with cursors := c.cursors.set stream r.next } else c
  | _, _ => c

def sanitize (name : String) : String :=
  let s := String.ofList (name.toList.filter fun ch => !(ch.toNat < 0x20 || (0x7f ≤ ch.toNat && ch.toNat ≤ 0x9f)))
  if s.isEmpty then "unnamed" else s

def hexOf (b : ByteArray) : String :=
  String.join (b.data.toList.map fun x =>
    let s := String.ofList (Nat.toDigits 16 x.toNat)
    if s.length < 2 then "0" ++ s else s)

/-- The members of `c` that `who` names: by display name, or by the start of the key in hex. -/
def named (c : Chat) (who : String) : List Key :=
  match c.group with
  | none => []
  | some g =>
    let byName := g.readers.keys.filter fun k => c.names.get? k == some who
    if byName.isEmpty && who.length ≥ 4 then
      g.readers.keys.filter fun k => (hexOf k).startsWith who.toLower
    else byName

def readResult : ReadOutcome → ReadResult × Option Index
  | .data p next => (.data (messageOf p), some next)
  | .notFound => (.missing .notFound, none)
  | .tombstone next => (.missing .tombstone, some next)

/-! ## Messages -/

def handle : Msg → CoreM Unit
  | .create name => do
    if (← getChat name).isSome then return
    setChat { name }
    emit (.create name false)
  | .join name => do
    if (← getChat name).isSome then return
    setChat { name, joining := some .minting }
    emit (.create name true)
  | .created name joining kp => withChat name fun c => do
    let c := { c with writeCap := kp.writeCap, nextWrite := kp.first }
    if joining then
      emit (.mint name kp.writeCap (← me))
      return c.notice "minting a voucher"
    return { c with group := some (Group.found kp.readCap [kp.readCap]) }.notice
      "a new group: /invite with a member's voucher code adds them"
  | .minted name m box1 => withChat name fun c => do
    let code := Base64.encode m.voucher
    emit (.awaitReply name m.secretKey m.readCap box1 c.writeCap)
    return { c with joining := some (.awaiting code m.secretKey m.readCap box1) }.notice
      s!"give this voucher code to a member of the group, and wait (it is also in {voucherFile name} in the state directory): {code}"
  | .opened name o => withChat name fun c => do
    let joined : Option (ReplyWho.ReplyWho × Group) := do
      let who ← ReplyWho.decode o.whoReply
      let reply ← ReplyWho.toJoinReply who
      let own := readCapOf o.mutatedWriteCap
      if reply.members.any (·.any fun m => keyOf m.1 == keyOf own) then none
      some (who, Group.joined own reply)
    match joined with
    | none => return { c with joining := none }.notice "the reply to our voucher cannot be read"
    | some (who, g) =>
      let names := who.pleaseAdds.foldl (fun (d : Dict Key String) p => match p with
        | some p => d.set (keyOf p.readCap) (sanitize p.name)
        | none => d) c.names
      return { c with group := some g, writeCap := o.mutatedWriteCap,
                      nextWrite := startOfWriteCap o.mutatedWriteCap, names, joining := none,
                      cursors := {} }.notice "joined the group"
  | .induct name code => withChat name fun c => do
    if c.group.isNone then return c.notice "join or create the group first"
    if c.inducting.isSome then return c.notice "already adding a member"
    match Base64.decode code with
    | none => return c.notice "that is not a voucher code"
    | some voucher =>
      emit (.readVoucher name voucher)
      return c.notice "reading the voucher"
  | .joinerPayload name voucher vwc payload box1 => withChat name fun c => do
    let (out, c) := onGroup c Group.beginInduction []
    let c ← enqueue c out
    return { c with inducting := some { voucher, payload, voucherWriteCap := vwc, box1, name := "" } }
  | .inducted name i => withChat name fun c => do
    let who := sanitize i.name
    let (o, c) := onGroup c (Group.introduceNow who i.mutatedReadCap) default
    let c ← if c.group.isSome then enqueue c [o] else pure c
    let c := (onGroup c (do if (← get).ledger.holding then Group.cancelInduction) ()).2
    let c := { c with inducting := none, names := c.names.set (keyOf i.mutatedReadCap) who }
    return c.notice s!"added ~{(Display.name who).text}: they now read everything said in this group"
  | .send name text => withChat name fun c => do
    let text := Display.outgoing text
    let some g := c.group | return c.notice "this conversation has not been joined yet"
    let content := Gcm.textContent (membershipHash (memberCaps g)) text
    let (id, c) := c.say fun id => { id, sender := g.me, text, status := .pending }
    let (out, c) := onGroup c (Group.compose (some content)) []
    enqueue c out (some content) (some id)
  | .wrote name job index next => do
    modifyFlight fun f => { f with writing := f.writing.erase name }
    withChat name fun c => do
      let some j := c.jobs.find? (·.id == job) | return c
      let mut c := { c with jobs := c.jobs.filter (·.id != job) }
      if let some t := j.token then
        c := (onGroup c (Group.written t index (some (.bytes j.box))) ()).2
        c := { c with nextWrite := next }
      if let some l := j.line then
        c := { c with log := c.log.map fun x =>
          if x.id == l then { x with status := .sent, idx64 := some (counter index) } else x }
      return c
  | .read name stream index outcome => do
    stopReading name stream
    withChat name fun c => do
      unless c.cursors.get? stream == some index do return c
      match outcome with
      | .notFound =>
        modifyFlight fun f => { f with reading := (name, stream) :: f.reading }
        emit (.wake name stream (backoff (← missed name stream)))
        return c
      | .tombstone next =>
        hit name stream
        return { c with cursors := c.cursors.set stream next }
      | .data plaintext next =>
        hit name stream
        let c := remark c stream plaintext
        let (es, c) := onGroup c (Group.observe stream index (messageOf plaintext) next) []
        let c ← effects c es
        return { c with cursors := c.cursors.set stream next }
  | .wake name stream => stopReading name stream
  | .scan name => withChat name fun c => do
    let some g := c.group | return c
    let mut c := c
    for stream in g.readers.keys do
      let (es, c') := onGroup c (Group.handle (.scan stream)) []
      c ← effects c' es
    return c.notice "scanning for missed messages"
  | .leave name => do
    modify fun (core, as) =>
      ({ core with state := { core.state with chats := core.state.chats.filter (·.name != name) } }, as)
    modifyFlight fun f => { writing := f.writing.erase name,
                            reading := f.reading.filter (·.1 != name),
                            misses := f.misses.filter (·.1.1 != name) }
  | .remove name who => withChat name fun c => do
    match named c who with
    | [k] =>
      let label := label c k
      let c := (onGroup c (Group.remove k) ()).2
      stopReading name k
      hit name k
      return { c with cursors := c.cursors.erase k,
                      log := c.log.filter (·.sender != k) }.notice
        s!"stopped reading {label} and deleted what they sent; they can still read this group"
    | [] => return c.notice s!"no member is called {who}"
    | _ => return c.notice s!"more than one member is called {who}: name them by the start of their key"
  | .clear name => withChat name fun c => return { c with log := [] }
  | .scanRead name stream index outcome => withChat name fun c => do
    let (result, next) := readResult outcome
    let (es, c) := onGroup c (Group.handle (.boxRead stream index result next)) []
    let c ← effects c es
    return followReader c stream
  | .walked name stream target skipped steps => withChat name fun c => do
    let (es, c) := onGroup c (Group.handle (.walked stream target skipped steps)) []
    let c ← effects c es
    return followReader c stream
  | .derived name stream indexes => withChat name fun c => do
    let (es, c) := onGroup c (Group.handle (.indexesDerived stream indexes)) []
    effects c es
  | .epoch n => do
    for c in (← get).1.state.chats do
      let some g := c.group | continue
      unless g.epoch < n do continue
      let (es, c) := onGroup c (Group.handle (.epochChanged n)) []
      setChat (← effects c es)
  | .failed name what => withChat name fun c => do
    let c := (onGroup c (do if (← get).ledger.holding then Group.cancelInduction) ()).2
    let c := match c.joining with
      | some .minting => { c with joining := none }
      | _ => c
    return { c with inducting := none }.notice what

end Core

/-- One message: the new core, and the network work to start. -/
def step (c : Core) (m : Msg) : Core × List Action :=
  let ((), (c, as)) := (do Core.handle m; Core.pump).run (c, #[])
  (c, as.toList)

/-- Begin again after a restart: whatever was under way is started afresh. An induction cannot
be, since its reply may have gone; it is given up, and the voucher has to be given again. -/
def resume (s : State) (maxPlaintext : Nat) : Core × List Action :=
  let go : CoreM Unit := do
    for c in s.chats do
      if c.writeCap.size = 0 then
        Core.emit (.create c.name c.joining.isSome)
        continue
      match c.joining with
      | some .minting => Core.emit (.mint c.name c.writeCap (← Core.me))
      | some (.awaiting _ sk rc box1) => Core.emit (.awaitReply c.name sk rc box1 c.writeCap)
      | none => pure ()
      if c.inducting.isSome then
        let c := (Core.onGroup c (do if (← get).ledger.holding then Group.cancelInduction) ()).2
        Core.setChat ({ c with inducting := none }.notice
          "adding a member was interrupted: give their voucher code again")
    Core.pump
  let ((), (c, as)) := go.run ({ state := s, maxPlaintext }, #[])
  (c, as.toList)

/-- Whether any member has acknowledged our line `l`. -/
def acknowledged (c : Chat) (l : Line) : Bool :=
  match c.group, l.idx64 with
  | some g, some n => g.ledger.ackedBy.values.any (n ≤ ·)
  | _, _ => false

end Posse
