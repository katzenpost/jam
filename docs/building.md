# Building jam

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

## Verifying a release

The binaries on the [releases](https://github.com/katzenpost/jam/releases) page are
reproducible: the same tag built anywhere with the toolchains it pins gives the same bytes. Each
release is built twice, on two runner images, and published only if both agree. To check one
yourself, with what Building lists and Rust 1.99.0 (`rustup toolchain install 1.99.0`):

    git clone https://github.com/katzenpost/jam
    cd jam
    git checkout v0.2.1
    FROM_SOURCE=1 make release
    curl -fsSL https://github.com/katzenpost/jam/releases/download/v0.2.1/SHA256SUMS | diff - dist/SHA256SUMS

No output from `diff` means your build and the release match. `FROM_SOURCE=1` skips
`lake exe cache get` and builds Mathlib too, so nothing you run was compiled by someone else; it
takes a few hours. Without it, `make release` is quicker and trusts Mathlib's downloaded files.
Either way, `gh attestation verify jam-v0.2.1-x86_64-linux --repo katzenpost/jam` checks that a
downloaded binary was built by this repository's release workflow.

