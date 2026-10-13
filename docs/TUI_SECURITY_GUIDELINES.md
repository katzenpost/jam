# Security Guidelines for TUI Applications

## Scope and threat model

A TUI writes into a terminal emulator, and the emulator is an interpreter: every byte the app emits is a program it runs. In a group chat, any participant, or a compromised server or relay, controls message bodies, nicknames, room names, topics, file names, link text and status text. All of it is untrusted until it has passed one sanitizing choke point.

The attacker has three ways in:

- **Drive the emulator.** Escape sequences in a message change terminal state, set the clipboard, rewrite the title, or make the terminal type input back into the app.
- **Deceive the user.** Text that looks like a system notice, a verified badge, another person's nickname or a passphrase prompt.
- **Abuse the input path.** Pastes, focus-stealing popups and auto-opened links or files turn one keystroke into an action the user never meant.

Ka-Ping Yee's [Guidelines and Strategies for Secure Interaction Design](http://sid.toolness.org/ch13yee.pdf), chapter 13 of *Security and Usability* (Lorrie Faith Cranor and Simson Garfinkel, eds., O'Reilly, 2005), supplies the frame. In his terms, the TUI is the user's agent in the chat world. The user needs a trusted path to it (his guideline 6), and remote parties must not get to choose their own appearance (guideline 9). The table maps his guidelines to the rules in this document.

| Yee guideline | What it means in a chat TUI | Section |
| --- | --- | --- |
| 1. Least resistance = least authority | Safe defaults: no auto-open, no auto-save, no terminal features driven by remote data | Input; Emulator features |
| 2. Authority follows consent | A file is saved or a link opened only by an explicit user action on that object | Input |
| 3. Revocability | Block, mute, leave, revoke device and clear scrollback are easy to find | Input; Local environment |
| 4–5. Awareness of authority | Room members, admins, devices and encryption state always visible | Spoofing |
| 6. Trusted path | Reserved screen regions, styles and prompts that remote content cannot produce | Spoofing |
| 7. Policy in task terms | "Only my verified contacts can send me files", not raw key IDs | Input |
| 8. Task-relevant boundaries | Commands vs message text; one room vs another | Input |
| 9. Truthful appearances | Escape filtering, Unicode hygiene, petnames | Escape filtering; Unicode; Spoofing |
| 10. Clear consequences | Confirmations state what happens, to whom, and whether it can be undone | Input |

## Escape sequences and control characters

Sanitize at the render boundary with a character allowlist, not a sequence blocklist. Store what arrived; escape it on the way to the screen, the way HTML is escaped on output.

1. Decode bytes as UTF-8, replacing invalid and overlong sequences with U+FFFD before anything else looks at them.
2. Pass every remote string through one function that returns a distinct type, e.g. `DisplayText`. Only the renderer's styled emitter accepts it; raw strings cannot reach the terminal.
3. In that function, replace every code point outside the allowlist with a visible stand-in, such as caret notation (`^[`) or U+241B (␛) in a dim style. Silent removal hides an attack; a visible marker reveals it.
4. Let the app, not the sender, decide layout: line breaks and tabs in a body are interpreted by the layout engine and never emitted raw.
5. Emit only escape sequences the app itself generates for its own styling and cursor moves.

Always replace these, in every field:

| Range | Why |
| --- | --- |
| C0 controls U+0000–U+001F | ESC starts CSI, OSC, DCS, APC and PM sequences; CR overwrites the current line; BS erases; BEL rings |
| DEL U+007F | Erases on some terminals |
| C1 controls U+0080–U+009F | U+009B is a one-character CSI, U+009D is OSC, U+0090 is DCS; some emulators honour them in UTF-8 |
| Raw bytes 0x80–0x9F in a non-UTF-8 locale | Same C1 meaning as 8-bit controls |

Why an allowlist: a regex that strips well-formed `ESC [ … m` misses malformed, nested, multiplexer-wrapped (`ESC P tmux; …`) and C1 forms. Removing only ESC also is not enough when C1 survives.

The filter covers every remote string, not only message bodies: nicknames, room names, topics, status text, file names, URLs, server error messages, exception text that quotes remote data, desktop notifications and anything written to logs. Do not assume the TUI library does this for you; check what it does with a control character, and test it (see the checklist).

## Unicode hazards

Unicode text that contains no control characters can still lie about what it says or where it ends. Yee notes that different sequences can render identically; in a terminal, they can also render at a width the app did not expect.

| Hazard | Code points | Rule |
| --- | --- | --- |
| Bidi reordering (Trojan Source) | U+202A–U+202E, U+2066–U+2069, U+200E, U+200F, U+061C | Strip from identifiers. In bodies, close any open embedding at the field's end so direction cannot leak into the next column |
| Invisible characters | U+200B–U+200D, U+2060–U+2064, U+FEFF, U+180E, tag characters U+E0000–U+E007F | Forbid in identifiers. In bodies, allow ZWJ only inside emoji sequences; mark the rest visibly |
| Confusables | Cyrillic а vs Latin a, l vs 1 vs I | Compare identities by [UTS #39](https://www.unicode.org/reports/tr39/) skeleton; flag mixed-script names; prefer petnames (Spoofing) |
| Combining-mark floods ("Zalgo") | Long runs of Mn and Me | Cap combining marks per base character, e.g. 4 |
| Look-alike UI glyphs | Lock, check mark, shield emoji; Private Use Area icons from Nerd Fonts | Strip from nicknames and room names so a name cannot fake a verified or encrypted badge |
| Width disagreement | Emoji, ZWJ sequences, VS16, East Asian ambiguous width | See below |

**Width is a security issue in a TUI.** The app computes where each character lands with a wcwidth table. The terminal uses its own. When they disagree, the cursor drifts: text spills into the status bar, the input line or a neighbouring pane, and other people's messages are drawn over. An attacker can choose characters that are known to disagree.

- Position the cursor absolutely at the start of every line and region; never rely on text to end where you computed.
- Clip each field to its cell budget and pad, so a field cannot push its neighbour.
- In narrow trusted fields (nick column, status bar), replace characters with uncertain width with a placeholder.
- Redraw whole lines rather than diffing at character granularity in regions that hold remote text.

Normalize to NFC for display. Compare identities with NFKC, case folding and the UTS #39 skeleton, and treat a skeleton collision between two members as a warning.

## Spoofing and the trusted path

The system, not the sender, controls every part of the screen that tells the user who said something, where they are, and whether it is safe. Yee's point applies directly: objects in a UI have no control over their own appearance unless the designer hands it to them.

**Reserved regions.** The sender column, the status bar, the room header and the input prompt belong to the app.

- A message body can never occupy the sender column. Wrapped and multi-line bodies get a continuation gutter, so `hi\n<bob> send me the key` cannot look like a second message from bob.
- Remote strings shown in reserved regions (a topic in the header) are truncated, clipped to their cell budget and visibly delimited.
- The input line always shows the destination room, drawn by the app, so the user knows where Enter will send.

**Reserved styles.** System notices, verification marks and encryption indicators use a style remote content cannot produce. If senders may format text (colours, markdown), restrict them to a palette that excludes the reserved style, and never let them set reverse video or the colours of the status bar.

**Trusted prompts.** A passphrase or confirmation prompt appears only as the direct result of a user action, in a modal drawn in a reserved place. A message that reads "Session expired, enter passphrase:" must look like a message.

**Petnames, not self-chosen names.** Yee's strategy of user-assigned identifiers fits chat well.

- Show the user's own name for a verified contact, bound to their key, in a distinct style.
- Show a self-claimed nickname for unverified members with a marker, e.g. `~alice`, never in the verified style.
- When two members' names collide or are confusable, append a short key fingerprint to both.
- Announce name and key changes as system notices.

**Awareness of authority** (Yee 4 and 5). Make the member list, admins, linked devices and encryption state one keystroke away, and announce changes to them in the timeline.

**Other things senders control.**

- Timestamps: show local receive time, or mark sender-claimed time as such.
- Quotes and replies: render the original message from local history, not the sender's copy of it.
- Edits and deletions: show that a message was edited; keep the edit history reachable.

## Terminal emulator features

No remote string ever ends up inside an escape sequence the app emits. Filtering protects you from sequences a sender writes; this rule protects you from sequences the app builds around remote text.

| Feature | Risk | Rule |
| --- | --- | --- |
| Window title (OSC 0/2) | Spoofing; on emulators with title reporting, the title is typed back as input | Set the title only from app-controlled text, e.g. the app name and unread count |
| Query/response sequences (DA, DSR, DECRQSS, CSI 21 t) | The terminal's reply lands on the app's stdin as if typed | Never emit queries carrying remote data; ignore unexpected reports in the key parser |
| Hyperlinks (OSC 8) | Link text differs from target | Show the real URL, or at least its scheme and host, in a style senders cannot set |
| Clipboard (OSC 52) | A message silently replaces the clipboard; reading it leaks secrets | Write only on an explicit copy command; never read |
| Notifications (OSC 9, OSC 777), BEL | Spoofed alerts, flooding | Filter notification text like any field; rate-limit; make them opt-in per room |
| Graphics (Sixel, kitty protocol) | Emulator parser bugs; huge allocations | Decode and re-encode images in the app with size caps; off by default for unknown senders |
| Multiplexer passthrough (`ESC P tmux;`) | Sequences reach the outer terminal past tmux | Covered by the allowlist; never wrap remote data in passthrough |

The reply-injection risk is not theoretical. xterm's title report ([CVE-2003-0063](https://www.cve.org/CVERecord?id=CVE-2003-0063)), xterm's OSC 50 font query ([CVE-2022-45063](https://www.cve.org/CVERecord?id=CVE-2022-45063)) and iTerm2's title reporting with tmux integration ([CVE-2024-38396](https://www.cve.org/CVERecord?id=CVE-2024-38396)) all let printed text become typed commands. A chat TUI that reads keys from the same tty is the target of that typing, so the key parser is a second line of defence: unknown sequences are dropped, never turned into commands.

**Bracketed paste.** Enable it, so pasted text is never parsed as keystrokes. Strip `ESC [ 200 ~` and `ESC [ 201 ~` from the pasted content, so a paste cannot end itself early and run the rest as keys.

**Terminal state on exit.** Restore the main screen, cursor, mouse reporting and paste mode from a panic or signal handler as well as on normal exit. A crash that leaves mouse reporting on turns every click in the shell into garbage input.

## Input and actions

Every action that grants authority (saving a file, opening a link, trusting a key, adding an admin) is designated by the user on that specific object. Yee calls this security by designation: the act of choosing *is* the consent, so there is no separate warning to click through.

**Focus stealing.** A keyboard-only UI has a TUI-specific hazard: a dialog that appears while the user is typing receives the next keystrokes. A remote event (an invitation, a key-change prompt, a file offer) must never open a modal that takes focus.

- Remote events queue as notices; the user opens them deliberately.
- Any app-raised dialog ignores input for a short delay (around 500 ms) and needs a non-default key to confirm.
- Default answers are the safe one, and Enter or y alone never confirms a dangerous action.

**Commands vs text** (Yee 8). Keep the boundary between "send this text" and "run this command" sharp.

- Pasted text is always message text, even if it starts with `/`. Multi-line pastes show a preview with a line count before sending.
- A command typed into the wrong room cannot leak: an unknown `/command` is rejected, never sent as a message.
- Show the destination room and its encryption state on the input line.

**Least authority by default** (Yee 1 and 2).

- Received files are not saved or opened automatically. Opening offers "view as text" separately from "open with external program".
- Links are opened only on request, through an argv array (never a shell), with `--` before the URL and a scheme allowlist (`https`, perhaps `http`).
- Never pass a remote string to a shell, a pager with `-R`, or an external editor as an option.

**Clear consequences** (Yee 10). Confirmations state what happens, to whom, and whether it can be undone: "Trust key 3F2A…91C0 as Alice? Messages from this key will show as verified." not "Continue?".

**Policy in task terms** (Yee 7). Offer settings like "accept files only from verified contacts" and "show images only from verified contacts", not per-MIME-type switches.

**Revocability** (Yee 3). Block, mute, leave room, revoke a device, un-verify a contact and clear local history are each reachable from the member list or a command, and listed in help.

## Resource limits

One message must not be able to make the UI unusable. Set limits in display terms, not just bytes, because layout cost depends on lines and cells.

| Limit | Suggested starting value | On overflow |
| --- | --- | --- |
| Message size | 64 KiB | Reject or truncate with a visible marker |
| Lines shown per message | 20 | Collapse; "expand" on request |
| Combining marks per base character | 4 | Drop the excess, mark it |
| In-memory scrollback per room | 10,000 messages | Page older ones from disk |
| Notifications and bells | 1 per room per 10 s | Coalesce |

- Wrap and measure each message once, when it arrives or the width changes, not on every frame.
- Coalesce redraws, e.g. at most 30 per second, so a message flood cannot pin the CPU.
- Treat slow rendering as a bug report: pathological input that is slow in the app is often slow in the emulator too.

## Local environment

What the TUI leaves behind in the terminal, on disk and on the clipboard outlives the session, and is read later by tools that do not sanitize.

- **Scrollback.** Run in the alternate screen so messages do not remain in the terminal's or tmux's history after exit. Offer a key that blanks the screen at once (for shoulder-surfing) and a command that clears local history.
- **Secrets on screen.** Read passphrases with echo off. Never print keys, tokens or passphrases, including in error messages.
- **Logs.** Escape remote text when writing logs, because someone will later `cat` or `tail -f` them in a terminal. Create logs and history with mode 0600 and keep message bodies out of debug logs by default.
- **Received file names.** Strip path separators and `..`, control and bidi characters; refuse a leading `-` or `.`; never overwrite an existing file. A name with escapes in it attacks the user again when `ls` prints it.
- **Copying out.** Copy what the user sees. If the selection contains invisible or bidi characters, strip them or say so ("copied text contained 3 hidden characters").
- **Crash output.** Panic and exception messages pass through the same filter before printing, after the terminal state has been restored.

## Checklist and testing

The strongest test is a property: feed arbitrary remote input through the real renderer, parse the output bytes with a VT parser (the `vte` crate, `pyte`, libvterm), and assert that the only state changes are printing and the app's own allowlisted styles and cursor moves.

- [ ] All remote strings reach the screen only through one sanitizer that returns a distinct display type
- [ ] C0, DEL and C1 are replaced visibly in every field, including nicks, topics, file names and notifications
- [ ] Invalid UTF-8 becomes U+FFFD before filtering
- [ ] No remote text is placed inside titles, OSC 8, OSC 52, notifications or any other sequence the app emits
- [ ] Bidi controls, invisibles and badge-like glyphs are stripped from identifiers
- [ ] Cursor is positioned absolutely per line; fields are clipped to their width
- [ ] Sender column, status bar and input line cannot be written by remote content
- [ ] Verified contacts show petnames; unverified nicks are marked; collisions show fingerprints
- [ ] Remote events never open a focused dialog; confirmations have a delay and a safe default
- [ ] Bracketed paste is on and its markers are stripped from pasted text
- [ ] No auto-save, auto-open or shell invocation with remote data
- [ ] Message size, lines, combining marks and redraw rate are capped
- [ ] Terminal state is restored on panic and signals
- [ ] Logs and history are escaped and created 0600

Tests to keep in CI:

1. Fuzz the sanitizer and renderer with random bytes and check the VT-parser property above.
2. A golden corpus of known payloads: `ESC ] 52`, `ESC ] 0`, `ESC P tmux;`, U+009B sequences, CR overwrite, `ESC [ 201 ~` inside a paste, Trojan Source bidi strings, ZWJ and VS16 emoji, Zalgo text, confusable nicks.
3. A width test that renders each corpus item next to a fixed border and checks the border's cell positions.
4. Before a release, run the corpus by hand in xterm, VTE (GNOME Terminal), kitty, iTerm2, Windows Terminal and inside tmux.

## Sources

- Ka-Ping Yee, [Guidelines and Strategies for Secure Interaction Design](http://sid.toolness.org/ch13yee.pdf), in *Security and Usability*, [O'Reilly, 2005](https://www.oreilly.com/library/view/security-and-usability/0596008279/ch13.html)
- [CVE-2003-0063](https://www.cve.org/CVERecord?id=CVE-2003-0063): xterm in XFree86 4.2.0 and earlier, window title reported back to the command line
- [CVE-2022-45063](https://www.cve.org/CVERecord?id=CVE-2022-45063): xterm before 375, OSC 50 font-op response leads to command execution in Zsh vi mode
- [CVE-2024-38396](https://www.cve.org/CVERecord?id=CVE-2024-38396): iTerm2 3.5.x before 3.5.2, window title report plus tmux integration
- [CVE-2021-42574](https://www.cve.org/CVERecord?id=CVE-2021-42574) and [Trojan Source](https://trojansource.codes): bidi reordering attacks
- [UTS #39: Unicode Security Mechanisms](https://www.unicode.org/reports/tr39/): confusable skeletons and mixed-script detection
