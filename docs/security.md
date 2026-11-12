# Security

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

