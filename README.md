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
| `/scan` | look again for messages a member's stream skipped |
| `/quit`, Esc | quit |

Tab and Shift-Tab move between groups, PgUp and PgDn scroll. Your own messages are marked `…`
until written, `✓` once written, and `✓✓` once a member acknowledges reading them.

A member's message too long for one box is not shown yet, nor are files.

## Testing

    make test                # in one process, against a simulated Pigeonhole
    ./test-integration.sh    # two members over the docker mixnet
    .lake/build/bin/posse-integration @katzenpost   # the same against a running kpclientd
