# Running jam

jam does not reach the mixnet itself. It talks to the Katzenpost client daemon, `kpclientd`,
which does the networking and the cryptography, so start the daemon first, with a client
configuration that says which mixnet to join.

This repository carries the configuration of the namenlos mixnet, in `config/client.toml`. It is
a configuration for `kpclientd`, not for jam, which never reads it.

Build `kpclientd` from [katzenpost](https://github.com/katzenpost/katzenpost) with Go, of at least
the version its `go.mod` names, using the top-level Makefile:

    git clone https://github.com/katzenpost/katzenpost
    cd katzenpost
    make kpclientd

This puts the daemon at `cmd/kpclientd/kpclientd`. Run it with the configuration and leave it
running:

    cmd/kpclientd/kpclientd -c /path/to/jam/config/client.toml

It logs to the terminal. Once it has fetched the mixnet's PKI document from the voting authorities
and connected to one of the gateways the file pins, jam can use it. namenlos's gateways change
from time to time; if the daemon cannot connect to any of them, pull this repository for the
latest `config/client.toml`.

The file's `[Listen]` section says where jam finds the daemon: `[Listen.Unix] Address =
"@katzenpost"`, the address jam uses by default. Several jam instances and katzenqt
can share one daemon.

Then start jam:

    .lake/build/bin/jam --name alice

| Option | |
|---|---|
| `--daemon ADDR` | the daemon's socket: `@katzenpost` (the default), a path, or `HOST:PORT` |
| `--state DIR` | where jam keeps its state and log; by default `$XDG_DATA_HOME/jam/${JAM_STATE:-default}` |
| `--name NAME` | your display name, which others see; remembered after the first run |
| `--log FILE` | the log file, by default `jam.log` in the state directory |
| `--wire-version 3\|4` | what jam writes and mints: 3, the map forms, or 4 (the default), the compact arrays; it reads both |

`JAM_LOG` sets the log level: `critical`, `error`, `warning`, `notice`, `info` (the default) or
`debug`.

## How groups work

There are no accounts and no servers. A group is its members: each writes to a stream of their
own on the mixnet and reads everyone else's. Two commands start you off, and they are for
different people:

- `/new NAME` starts a group of your own, with you its only member.
- `/join NAME` is what someone *else* types to join an existing group. NAME is only what that
  group will be called on their screen; it need not match what the founder called it. jam shows
  them a voucher code.
- `/invite CODE` is what a member of the group then types, with that code, to let them in.

So you never `/join` your own group: you `/new` it, and the people you want `/join` it.

## Starting a group and adding someone

Say Alice starts a group and adds Sam. They hand the voucher code to each other out of band:
another messenger, a QR code, in person.

1. Alice types `/new friends`.
2. Sam types `/join friends`. jam mints a voucher and shows its code in the conversation, as a
   QR code too where the window has room, and writes it to `voucher-friends.txt` in Sam's state
   directory, so that it can be copied whole.
   Sam sends Alice the code.
3. Alice selects `friends` (Tab moves between groups) and types `/invite CODE`, pasting the code.
   Whoever holds a code can read everything said in the group from then on, so Alice takes it
   only from the person she means to add.
4. A little later Alice sees `-- added ~sam` and Sam `-- joined the group`. Each step crosses the
   mixnet a few times, so this takes a few minutes.

Then they just type. Any member can add more people the same way, and everyone hears of them:
`-- ~sam added ~kim`.

## Two instances on one machine

Give each its own state directory, and they can share one daemon:

    .lake/build/bin/jam --name alice --state ~/jam-alice
    .lake/build/bin/jam --name bob --state ~/jam-bob

## With katzenqt

jam speaks katzenqt's group chat, as of katzenqt's main branch: a jam member can join
a katzenqt group and the other way round, with the same voucher codes.
`scripts/interop-katzenqt.sh` runs both directions with `katzenqt-headless`. A katzenqt older
than its wire version 4 reads only version 3: give jam `--wire-version 3` to talk to one.

