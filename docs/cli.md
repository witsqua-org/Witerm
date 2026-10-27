# Command Line

`witerm` starts, shares, and attaches to Mac terminal sessions from any terminal. It talks to the same background service as the Mac app, so a session started in one shows up in the other at once, with the same sharing and control.

## Install

In Witerm, open **Settings → Command Line** and choose **Install**. This links `~/.local/bin/witerm` to the copy inside the app, so the command updates with the app. If your shell can't find it:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

The local terminal must be on (Settings → General).

## Commands

```sh
witerm new                 # Start a session in this folder and attach to it
witerm new --share         # ...and let paired devices reach it
witerm share [session]     # Share a session (default: the one you're in)
witerm unshare [session]   # Stop sharing; paired devices disconnect, the session keeps running
witerm rename <session> <name>   # Change a session's display name
witerm sessions            # List sessions, sharing, and who is attached
witerm attach <session>    # Attach with control; --view to watch
witerm status              # Background service, tmux, and remote access
```

- **Naming a session.** Use its ID, a unique ID prefix of at least 4 characters, or its exact name. `new` names the session after the folder unless you pass `--name`.
- **`new` starts a fresh shell** in the current folder. It can't take over the shell you typed it in, and your environment (including virtual environments) isn't copied; the new shell starts from your login profile.

### While attached

Your terminal's size becomes the session's size.

| Keys (after Enter) | Effect |
|---|---|
| `~.` | Detach. The session keeps running. |
| `~?` | List escapes |
| `~~` | Type a `~` |

- `--escape <char>` picks another escape character; `--escape none` turns escapes off.
- Detaching, suspending, closing the window, or a signal always restores your terminal.
- If your terminal can't keep up with output, the command disconnects with a backpressure error. The session keeps running; attach again to continue.

**Control.** One device controls a session at a time. If another device has it, `attach` exits with code 5 instead of taking over; use `--view` to watch. Detaching releases control at once, so a phone can take it.

## Sharing

Sessions are private until shared. Sharing lets **already paired** devices list and open a session, within the access each was granted. The command never pairs or approves devices; do that in the app.

`share` reports where remote access really stands:

| Remote access | Meaning |
|---|---|
| `ready` | A server has accepted this Mac. Paired devices can open the session now. |
| `waiting` | Allow Remote Access is on, but no server has accepted the Mac yet. |
| `off` | Allow Remote Access is off. The session is shared, but nobody can reach it. |

`witerm share --wait 30` waits up to 30 seconds for `ready`.

| Action | Effect |
|---|---|
| Detach | You leave; the session keeps running. |
| `unshare` | Paired devices disconnect; the session keeps running. |
| `rename` | Changes only the display name, here and on paired devices. Attached viewers and the shell are unaffected. |
| **End Session** in the app | The shell and its programs end. Only the app can do this. |

## Scripting

- `--json` prints one JSON value on stdout and never attaches.
- Errors go to stderr as `{"error":{"code","message","exit"}}`.
- Nothing is interactive unless you attach in a real terminal.
- `WITERM_AGENT_SOCKET` (or `--socket`) points at another service socket, for development.

| Exit code | Meaning |
|---|---|
| 0 | Success |
| 1 | Other failure |
| 2 | Usage error, or a request the service rejected |
| 3 | Background service unavailable or not installed |
| 4 | No such session or folder |
| 5 | Another device controls the session |
| 6 | tmux isn't installed |
| 7 | `--wait` ended before remote access was ready |

```sh
id=$(witerm new --share --detach --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["session"]["id"])')
witerm share "$id" --wait 30 && echo "Open it on your phone"
```

## Testing

```sh
swift test --package-path apps/mac-agent --filter CLI
# The same integration cases against the installed, signed command:
WITERM_CLI_TEST_BINARY="$PWD/.build/Applications/Witerm.app/Contents/Helpers/witerm" \
  swift test --package-path apps/mac-agent --filter CLIIntegrationTests
```

The tests run the real `witerm` binary against a private broker and tmux server, on real pseudo-terminals. They cover:

- typing, resizing, `~.` detach, the last output before the shell exits, and control release
- terminal restoration and correct exit codes when stdout or stderr is blocked and never read, including output blocked before attaching
- termination right after startup, repeated 20 times
- discarding stale type-ahead while delivering new input

A process that times out fails the test before cleanup kills it.
