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

## Running

Start `kpclientd`, then:

    lake exe cache get && lake build posse
    .lake/build/bin/posse --name alice

| Option | |
|---|---|
| `--daemon ADDR` | the daemon's socket: `@katzenpost` (the default), a path, or `HOST:PORT` |
| `--state DIR` | where posse keeps its state and log; by default `$XDG_DATA_HOME/posse/${POSSE_STATE:-default}` |
| `--name NAME` | your display name |
| `--log FILE` | the log file, by default `posse.log` in the state directory |
| `--sim` | an in-memory network instead of the daemon, to try posse alone |

`POSSE_LOG` sets the log level: `critical`, `error`, `warning`, `notice`, `info` (the default) or
`debug`.

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

posse follows [docs/TUI_SECURITY_GUIDELINES.md](docs/TUI_SECURITY_GUIDELINES.md): everything
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
