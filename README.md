# posse

A terminal group chat over the [Katzenpost](https://katzenpost.network) mixnet, written in Lean,
that speaks [katzenqt](https://github.com/katzenpost/katzenqt)'s group chat: a posse member and a
katzenqt member can be in one group.

- The group chat protocol is CryptWalker's member state machine
  (`CryptWalker/GroupChat/Member`), the model katzenqt's traces are replayed through, with its
  proofs. posse runs that code: it drives the member as katzenqt's adapter does and does the IO.
- Boxes are read and written through the client daemon, `kpclientd`, with the Lean
  [thin client](https://github.com/katzenpost/thin_client).
- The screen is drawn with [Tessera](https://github.com/katzenpost/Tessera), and posse logs with
  [Logger](https://github.com/katzenpost/Logger).

## Building

posse is Lean, with two small Rust libraries underneath it: the terminal (crossterm, through
Tessera) and the daemon's unix socket. Building needs:

- **Lean**, through [elan](https://github.com/leanprover/elan). It installs the toolchain in
  `lean-toolchain` by itself.
- **Rust**, through [rustup](https://rustup.rs): `cargo` must be on the `PATH` while building.
- **git**, and about 8 GB of disk: CryptWalker depends on Mathlib, whose compiled files
  `lake exe cache get` downloads rather than building them for hours.

Then:

    git clone https://github.com/katzenpost/posse
    cd posse
    lake exe cache get
    lake build posse

The program is `.lake/build/bin/posse`. The first build takes a while; later ones take seconds.

## Running

posse talks to the mixnet through the Katzenpost client daemon, `kpclientd`, which does the
networking and the cryptography. Build it from [katzenpost](https://github.com/katzenpost/katzenpost)
with Go:

    git clone https://github.com/katzenpost/katzenpost
    cd katzenpost/cmd/kpclientd && go build

and run it with the client configuration of the mixnet you want, for example:

    ./kpclientd -c client.toml

Its `[Listen]` section says where posse finds it; `[Listen.Unix] Address = "@katzenpost"` is the
address posse uses by default. Several posse instances, and katzenqt, can share one daemon.

Then start posse:

    .lake/build/bin/posse --name alice

| Option | |
|---|---|
| `--daemon ADDR` | the daemon's socket: `@katzenpost` (the default), a path, or `HOST:PORT` |
| `--state DIR` | where posse keeps its state and log; by default `$XDG_DATA_HOME/posse/${POSSE_STATE:-default}` |
| `--name NAME` | your display name, which others see; remembered after the first run |
| `--log FILE` | the log file, by default `posse.log` in the state directory |
| `--sim` | an in-memory network instead of the daemon, to try posse alone |

`POSSE_LOG` sets the log level: `critical`, `error`, `warning`, `notice`, `info` (the default) or
`debug`.

### Trying it alone

    .lake/build/bin/posse --sim --name alice --state /tmp/posse-try

needs no daemon: type `/new test`, then a message. Nothing leaves your machine.

### Starting a group and adding someone

There are no accounts or servers: a group is its members' streams, and you join one by handing a
member a contact voucher, out of band (another messenger, a QR code, in person).

1. The founder types `/new friends`.
2. The person joining types `/join friends`. posse mints a voucher and shows its code in the
   conversation, and writes it to `voucher-friends.txt` in the state directory, so that it can be
   copied whole; they send that code to the founder.
3. The founder selects `friends` (Tab moves between groups) and types `/invite CODE`, pasting the
   code. Whoever holds the code can read everything said in the group from then on, so take it
   only from the person you mean to add.
4. A little later the founder sees `-- added ~sam` and the newcomer `-- joined the group`. Each
   step crosses the mixnet a few times, so this takes a few minutes.

Then just type. Any member can add more people the same way, and everyone hears of them: `-- ~sam
added ~kim`.

### Two instances on one machine

Give each its own state directory, and they can share one daemon:

    .lake/build/bin/posse --name alice --state ~/posse-alice
    .lake/build/bin/posse --name bob --state ~/posse-bob

### With katzenqt

posse speaks katzenqt's group chat, as of katzenqt's `acks-idx64` branch: a posse member can join
a katzenqt group and the other way round, with the same voucher codes.
`scripts/interop-katzenqt.sh` runs both directions with `katzenqt-headless`.

## Using it

The groups are on the left, the selected conversation in the middle, and on the right everyone
who reads what is written there, with the start of each member's key: a display name is only
what its owner chose, and two members may choose the same one. The log is below; F2 hides it.
The line you type into names the group it goes to.

| Command | |
|---|---|
| `/new NAME` | found a group |
| `/join NAME` | join a group: posse mints a contact voucher and shows its code, to give to a member |
| `/invite CODE` | add the member whose voucher code you were given to the selected group |
| `/remove WHO` | stop reading a member, named by display name or by the start of their key, and delete what they sent; they can still read the group, since every member holds every member's read cap |
| `/leave GROUP` | stop reading and writing the selected group and delete it here; the others keep it |
| `/clear` | delete the selected conversation's lines here |
| `/scan` | look again for messages a member's stream skipped |
| `/quit`, Esc | quit |

Tab and Shift-Tab move between groups, PgUp and PgDn scroll, F2 hides the log and F10 blanks the
screen. Your own messages are marked `...` until written, `✓` once written, and `✓✓` once a member acknowledges reading them.

A member's message too long for one box is not shown yet, nor are files.

## Security

posse follows Tessera's [TUI security guidelines](https://github.com/katzenpost/Tessera/blob/main/docs/TUI_SECURITY_GUIDELINES.md): everything
another member sends is untrusted, and the terminal is an interpreter.

- **One filter.** Every string reaches the screen as `Shown`, Tessera's `Untrusted.Safe`, made by
  [`Tessera.Untrusted`](https://github.com/katzenpost/Tessera), which every TUI showing text from
  elsewhere needs. It keeps characters by an allowlist of those whose width the terminal and
  Tessera agree on, and shows anything else: `␛` and the other Control Pictures for control
  characters, `␦` for the rest, so an attempt is visible rather than hidden. Bidi controls,
  invisible characters, private-use glyphs and tag characters are refused; combining accents are
  capped at four a letter; a message shows at most 20 lines. Tessera itself never writes a
  character that takes no cell. `Posse.Display` adds posse's rules for names.
- **posse decides who said what.** A member's chosen name is shown after `~`, ours as `me`; a name
  cannot hold check marks or other marks posse uses, and is cut at 30 characters. Names that look
  alike (case, look-alike Cyrillic and Greek letters, `0`/`o`, `1`/`l`), names like ours and names
  mixing scripts show the start of the member's key. Every row of a message after its first
  begins with a gutter, so a newline or a wrap cannot start a row that passes for another
  message, and posse's notices are drawn in a style no message has.
- **Input.** Bracketed paste is on and its markers are removed from what is pasted. A paste into
  an empty line is a message, never a command; a message of several lines is sent on a second
  Enter, after posse says how many lines it is. Control and bidi characters are taken out of what
  you send. An unknown `/command` is refused, not sent.
- **Nothing on its own.** posse sets no title and writes no clipboard, opens no links and saves no
  files; remote events never open a prompt.
- **On disk.** The state directory is created 0700 and `state.cbor` and `posse.log` 0600. The log
  is filtered like the screen and holds no message text. `state.cbor` is not encrypted: it holds
  your write caps and every message. `/clear` deletes a conversation's lines, `/leave` the group.
- **Leaving.** posse runs in the alternate screen, so the conversation does not stay in the
  terminal's scrollback. SIGTERM, SIGHUP and SIGQUIT restore the terminal before exiting, and F10
  blanks the screen at once.

Not yet: petnames bound to keys, the whole of UTS #39's confusables, and a test that parses the
bytes sent to the terminal with a VT parser; the tests check every cell drawn instead. East Asian
ambiguous-width characters are taken as one cell, as terminals outside CJK locales draw them.

## Testing

    make test                # in one process, against a simulated Pigeonhole, and the security tests
    ./test-integration.sh    # two members over the docker mixnet
    .lake/build/bin/posse-integration @katzenpost   # the same against a running kpclientd
