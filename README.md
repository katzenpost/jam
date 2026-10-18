# jam

A terminal group chat over the [Katzenpost](https://katzenpost.network) mixnet, written in Lean,
that speaks [katzenqt](https://github.com/katzenpost/katzenqt)'s group chat: a jam member and a
katzenqt member can be in one group.

- The group chat protocol is Cryptlib's member state machine
  (`Cryptlib/Protocols/GroupComm/GroupChatKatzenqt1/Member`), the model katzenqt's traces are replayed through, with its
  proofs. jam runs that code: it drives the member as katzenqt's adapter does and does the IO.
- Boxes are read and written through the client daemon, `kpclientd`, with the Lean
  [thin client](https://github.com/katzenpost/thin_client).
- The screen is drawn with [Tessera](https://github.com/katzenpost/tessera), and jam logs with
  [Logger](https://github.com/katzenpost/Logger).

## Building

jam is Lean, with two small Rust libraries underneath it: one for the terminal (crossterm,
through Tessera) and one for the daemon's unix socket. You need:

- **Lean**, through [elan](https://github.com/leanprover/elan). It installs the toolchain named in
  `lean-toolchain` by itself.
- **Rust**, through [rustup](https://rustup.rs). There is no separate Rust step: Lake runs `cargo`
  itself while building, so `cargo` only has to be on the `PATH` (rustup's installer puts
  `~/.cargo/bin` there; in a shell started before it, `source ~/.cargo/env`).
- **git**, and about 8 GB of disk.

Then:

    git clone https://github.com/katzenpost/jam
    cd jam
    lake exe cache get
    lake build jam

`lake exe cache get` fetches the dependencies, and downloads Mathlib's compiled files (several
GB, which Cryptlib needs) rather than building them for hours. `lake build jam` then
compiles the rest, Rust included, which takes several minutes the first time and seconds after.
The program is `.lake/build/bin/jam`. `make test` builds and runs the tests.

If the build stops with `could not execute external process 'cargo'`, `cargo` is not on the
`PATH`. A note that VCVio's `leanfalcon` native backend is disabled is expected, and harmless:
jam does not use it.

## Running

jam talks to the mixnet through the Katzenpost client daemon, `kpclientd`, which does the
networking and the cryptography. Build it from [katzenpost](https://github.com/katzenpost/katzenpost)
with Go, of at least the version its `go.mod` names:

    git clone https://github.com/katzenpost/katzenpost
    cd katzenpost/cmd/kpclientd && go build

and run it with the client configuration of the mixnet you want, for example:

    ./kpclientd -c client.toml

Its `[Listen]` section says where jam finds it; `[Listen.Unix] Address = "@katzenpost"` is the
address jam uses by default. Several jam instances, and katzenqt, can share one daemon.

Then start jam:

    .lake/build/bin/jam --name alice

| Option | |
|---|---|
| `--daemon ADDR` | the daemon's socket: `@katzenpost` (the default), a path, or `HOST:PORT` |
| `--state DIR` | where jam keeps its state and log; by default `$XDG_DATA_HOME/jam/${JAM_STATE:-default}` |
| `--name NAME` | your display name, which others see; remembered after the first run |
| `--log FILE` | the log file, by default `jam.log` in the state directory |

`JAM_LOG` sets the log level: `critical`, `error`, `warning`, `notice`, `info` (the default) or
`debug`.

### How groups work

There are no accounts and no servers. A group is its members: each writes to a stream of their
own on the mixnet and reads everyone else's. Two commands start you off, and they are for
different people:

- `/new NAME` starts a group of your own, with you its only member.
- `/join NAME` is what someone *else* types to join an existing group. NAME is only what that
  group will be called on their screen; it need not match what the founder called it. jam shows
  them a voucher code.
- `/invite CODE` is what a member of the group then types, with that code, to let them in.

So you never `/join` your own group: you `/new` it, and the people you want `/join` it.

### Starting a group and adding someone

Say Alice starts a group and adds Sam. They hand the voucher code to each other out of band:
another messenger, a QR code, in person.

1. Alice types `/new friends`.
2. Sam types `/join friends`. jam mints a voucher and shows its code in the conversation, and
   writes it to `voucher-friends.txt` in Sam's state directory, so that it can be copied whole.
   Sam sends Alice the code.
3. Alice selects `friends` (Tab moves between groups) and types `/invite CODE`, pasting the code.
   Whoever holds a code can read everything said in the group from then on, so Alice takes it
   only from the person she means to add.
4. A little later Alice sees `-- added ~sam` and Sam `-- joined the group`. Each step crosses the
   mixnet a few times, so this takes a few minutes.

Then they just type. Any member can add more people the same way, and everyone hears of them:
`-- ~sam added ~kim`.

### Two instances on one machine

Give each its own state directory, and they can share one daemon:

    .lake/build/bin/jam --name alice --state ~/jam-alice
    .lake/build/bin/jam --name bob --state ~/jam-bob

### With katzenqt

jam speaks katzenqt's group chat, as of katzenqt's `acks-idx64` branch: a jam member can join
a katzenqt group and the other way round, with the same voucher codes.
`scripts/interop-katzenqt.sh` runs both directions with `katzenqt-headless`.

## Using it

```
 ≋ jam  friends  4 members · epoch 12                                    daemon @katzenpost
╭ groups ────────────╮╭ friends ───────────────────────────────────╮╭ members ─────────────╮
│friends          3  ││~sam     hey there                          ││me                3f2a│
│work      joining…  ││       ┊ a second line                      ││~sam              91c0│
│                    ││me       on my way √√                      ││~kim (!)          77ab│
│                    ││-- ~sam added ~kim                          ││                      │
╰────────────────────╯╰────────────────────────────────────────────╯╰──────────────────────╯
╭ [friends] ─────────────────────────────────────────────────────────────────────────────╮
│› /inv                                                                                  │
╰────────────────────────────────────────────────────────────────────────────────────────╯
 /invite CODE · let in the person whose voucher code you were given  Tab        0 to write
```

A bar across the top names the group, its members and its epoch. The groups are on the left,
the selected conversation in the middle, and on the right everyone who reads what is written
there, with the start of each member's key: a display name is only what its owner chose, and two
members may choose the same one. The log is below, each line coloured by its level; F2 hides it.
The line you type into names the group it goes to, and the bar below it shows the keys, or, while
you type a command, what it does.

Each member's name is drawn in a colour of their own, picked from their key, so it is the same on
every screen; your own name, `me`, jam's notices, and the frame are drawn in colours no member's
can be. With no group yet, jam shows how to start one. `NO_COLOR` turns colour off, and a terminal
of 256 or 16 colours gets the nearest ones.

| Command | |
|---|---|
| `/new NAME` | start a group of your own |
| `/join NAME` | join someone else's group, calling it NAME here: jam shows a voucher code to give to one of its members |
| `/invite CODE` | let the person whose voucher code you were given into the selected group |
| `/remove WHO` | stop reading a member, named by display name or by the start of their key, and delete what they sent; they can still read the group, since every member holds every member's read cap |
| `/leave GROUP` | stop reading and writing the selected group and delete it here; the others keep it |
| `/clear` | delete the selected conversation's lines here |
| `/scan` | look again for messages a member's stream skipped |
| `/help`, F1 | show every command and key |
| `/quit`, Esc | quit |

### Several groups

You can be in any number of groups: each `/new` or `/join` adds one to the groups pane, and
selects it.

- **Tab** selects the next group, **Shift-Tab** the one before. The selected group is
  highlighted; the conversation and the members pane show it.
- What you type goes to the selected group only, and the line you type into says which:
  `[friends] >`. So do `/invite`, `/remove`, `/leave`, `/clear` and `/scan`.
- The other groups go on reading in the background. One with lines you have not seen shows how
  many, `work (3)`; one you are still joining shows `joining…`, and one adding a member
  `adding…`.

### Keys

| Key | |
|---|---|
| Tab, Shift-Tab | the next or previous group; Tab completes a `/command` you have begun |
| PgUp, PgDn, the wheel | scroll the conversation back and forward |
| click | select a group; the wheel over the groups moves through them |
| Left, Right, Home, End | move in the line you are typing |
| Ctrl-A, Ctrl-E, Ctrl-W, Ctrl-U | to the start, to the end, delete a word, delete to the start |
| Up, Down | the lines you sent before |
| F1 | show or hide every command and key |
| F2 | hide or show the log |
| F10 | blank the screen at once, and bring it back |
| Esc | close the help, drop a paste of several lines, or quit |
| Ctrl-C | quit |

Your own messages are marked `…` until written, `√` once written, and `√√` once a member
acknowledges reading them. A paste of several lines shows as `≡ 3 lines pasted` until Enter
sends it or Esc drops it. While you are joining a group, its voucher code stays in a bar at the
top of its conversation.

A member's message too long for one box is not shown yet, nor are files.

## Security

jam follows Tessera's [TUI security guidelines](https://github.com/katzenpost/tessera/blob/main/docs/TUI_SECURITY_GUIDELINES.md): everything
another member sends is untrusted, and the terminal is an interpreter.

- **One filter, in the types.** Everything drawn is a Tessera `Text`, which cannot hold a control
  character or an escape sequence. jam's own words are literals checked when it compiles; text
  from the network is filtered by
  [`Tessera.Untrusted`](https://github.com/katzenpost/tessera), and is of a type Tessera keeps out
  of the places a program keeps for its own words. The filter keeps characters by an allowlist of those whose width the terminal and
  Tessera agree on (checked against libvterm), and shows anything else: `␛` and the other Control Pictures for control
  characters, `␦` for the rest, so an attempt is visible rather than hidden. Bidi controls,
  invisible characters, private-use glyphs and tag characters are refused; combining accents are
  capped at four a letter; a message shows at most 20 lines. Tessera proves that a terminal reads
  what it writes as printed characters and its own control sequences, and nothing else.
  `Jam.Display` adds jam's rules for names.
- **jam decides who said what.** A member's chosen name is shown after `~`, ours as `me`; a name
  is a Tessera `Ident`, which cannot hold a badge glyph, nor marks jam uses, and is cut at 30
  characters. Names that look
  alike (case, look-alike Cyrillic and Greek letters, `0`/`o`, `1`/`l`), names like ours and names
  mixing scripts show the start of the member's key. Every row of a message after its first
  begins with a gutter, so a newline or a wrap cannot start a row that passes for another
  message.
- **Colours.** A member's name is drawn in a colour jam picks from their key, a Tessera
  `RemoteStyle`: one of five basic colours, which Tessera proves is never one of the reserved
  styles. jam's notices, `me`, the frame and the bars are drawn in reserved styles
  (`Jam.Theme`, each proved so). So no member, whatever they are called or send, is drawn the way
  jam draws its own words, and that holds in fewer colours too: Tessera keeps a style as reserved
  as it was when it draws for a terminal of 256 or 16 colours, or none.
- **Input.** Only a key, a paste or a click read from the terminal can act for you: Tessera
  marks each with a proof that only its application loop can make. Bracketed paste is on and its
  markers are removed from what is pasted. A paste into
  an empty line is a message, never a command; a message of several lines is sent on a second
  Enter, after jam says how many lines it is. Control and bidi characters are taken out of what
  you send. An unknown `/command` is refused, not sent.
- **Nothing on its own.** jam sets no title and writes no clipboard, opens no links and saves no
  files; remote events never open a prompt.
- **On disk.** The state directory is created 0700 and `state.cbor` and `jam.log` 0600. The log
  is filtered like the screen and holds no message text. `state.cbor` is not encrypted: it holds
  your write caps and every message. `/clear` deletes a conversation's lines, `/leave` the group.
- **Leaving.** jam runs in the alternate screen, so the conversation does not stay in the
  terminal's scrollback. SIGTERM, SIGHUP and SIGQUIT restore the terminal before exiting, and F10
  blanks the screen at once.

Not yet: petnames bound to keys, and the whole of UTS #39's confusables. East Asian
ambiguous-width characters are taken as one cell, as terminals outside CJK locales draw them.

## Testing

    make test                # in one process: the screen, the keys and commands, and the security tests;
                             # the core is tested in group_chat_client
    ./test-integration.sh    # two members over the docker mixnet
    .lake/build/bin/jam-integration @katzenpost   # the same against a running kpclientd
